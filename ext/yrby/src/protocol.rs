// Pure Rust protocol helpers (no Ruby interop).
//
// Client ids are not validated here, on purpose: every legitimate peer (browser
// Yjs, and yrs's own `ClientID::random`) already emits 53-bit ids, so it's the
// client's responsibility not to send a bad one, and we don't want to own that
// logic.
use yrs::encoding::read::{Cursor, Read};
use yrs::sync::protocol::MessageReader;
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::{Decode, DecoderV1};
use yrs::{Doc, ReadTxn, Transact};

/// Classify a frame: a non-zero code only for exactly one well-formed message
/// that consumes the whole buffer (the codes are the match arms below).
pub(crate) fn classify_message(bytes: &[u8]) -> u8 {
    let mut decoder = DecoderV1::new(Cursor::new(bytes));
    let msg = match Message::decode(&mut decoder) {
        Ok(msg) => msg,
        Err(_) => return 0, // empty or malformed
    };
    // Any remaining byte means a second message or trailing garbage.
    if decoder.read_u8().is_ok() {
        return 0;
    }
    match msg {
        Message::Sync(SyncMessage::SyncStep1(_)) => 1,
        Message::Sync(SyncMessage::SyncStep2(_)) | Message::Sync(SyncMessage::Update(_)) => 2,
        Message::Awareness(_) => 3,
        Message::AwarenessQuery => 4,
        _ => 0, // Auth / Custom: not part of our model
    }
}

/// Merge the document-update deltas (Update / SyncStep2 payloads) carried by a
/// frame into one update, or `None` if the frame carries no document change
/// (a request, an awareness update, or a no-op handshake SyncStep2).
pub(crate) fn merged_doc_update(bytes: &[u8]) -> Result<Option<Vec<u8>>, String> {
    let mut decoder = DecoderV1::new(Cursor::new(bytes));
    let mut updates: Vec<Vec<u8>> = Vec::new();
    for msg in MessageReader::new(&mut decoder) {
        match msg.map_err(|e| e.to_string())? {
            Message::Sync(SyncMessage::Update(u)) | Message::Sync(SyncMessage::SyncStep2(u)) => {
                updates.push(u)
            }
            _ => {}
        }
    }
    let merged = match updates.len() {
        0 => return Ok(None),
        1 => updates.pop().unwrap(),
        _ => yrs::merge_updates_v1(&updates).map_err(|e| e.to_string())?,
    };
    let update = yrs::Update::decode_v1(&merged).map_err(|e| e.to_string())?;
    // A genuine no-op (e.g. the empty SyncStep2 in an opening handshake) carries
    // no structs, no deletes, and no dependencies. We must NOT treat a causally-
    // pending update as a no-op: such an update reports an empty
    // state_vector (its structs can't integrate yet), but it still carries
    // content and a non-empty lower bound (the deps it's waiting on). Dropping it
    // here would silently swallow a gappy update instead of rejecting + resyncing.
    if update.state_vector().is_empty()
        && update.delete_set().is_empty()
        && update.state_vector_lower().is_empty()
    {
        return Ok(None);
    }
    Ok(Some(merged))
}

/// True if applying `update_bytes` to `doc` would integrate cleanly: every
/// dependency the update references is already present (the doc's state vector
/// covers the update's lower bound). A pure read; does not mutate the doc.
/// When false, applying it would park a pending struct, the signal that an
/// earlier, causally-prior update is missing.
pub(crate) fn update_is_ready(doc: &Doc, update_bytes: &[u8]) -> Result<bool, String> {
    let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;
    Ok(doc.transact().state_vector() >= update.state_vector_lower())
}

/// True if applying `update_bytes` would actually change `doc`, i.e. it carries
/// content (an insert, a format, or a deletion) the doc doesn't already have.
/// This lets the server make durable side effects exactly-once: a lost-ack retry
/// re-sends an update the server already applied; that retry is causally ready
/// (so `update_is_ready` is true) but must not re-run `on_change`.
///
/// We can't read the update's own state vector to decide this: yrs reports an
/// empty state_vector() for a causally-pending diff (e.g. a resync delta whose
/// structs depend on updates the doc has but the standalone update doesn't),
/// which would look identical to a no-op. So measure the real effect on an
/// independent probe seeded with the doc's current state (never mutating the real
/// doc), then compare the probe before and after applying the update:
///
/// - **Insert/format-only updates** grow the probe's state vector, so comparing
///   the state vector is enough — and cheaper than a full re-encode.
/// - **Delete-bearing updates** don't move the state vector (a deletion tombstones
///   an existing struct rather than adding one), so we compare the full encoded
///   state, which carries the delete set. An already-applied pure-delete retry
///   re-encodes byte-identically → false; a genuinely new deletion changes the
///   delete set → true. This is exact but pays for two full encodes, so only
///   delete-bearing frames — a minority — take that path.
///
/// Earlier this branch was conservative: any delete-bearing update returned true
/// (record it), which double-recorded and re-broadcast pure-delete retries the
/// server had already integrated. The exact comparison removes that duplication
/// while still never dropping a real deletion. Assumes the update is already
/// causally ready.
pub(crate) fn update_advances_doc(doc: &Doc, update_bytes: &[u8]) -> Result<bool, String> {
    let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;
    let has_deletes = !update.delete_set().is_empty();

    // Seed an independent probe with the doc's current state so we can measure the
    // update's effect without mutating the real doc.
    let probe = Doc::new();
    let current = doc
        .transact()
        .encode_state_as_update_v1(&yrs::StateVector::default());
    probe
        .transact_mut()
        .apply_update(yrs::Update::decode_v1(&current).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;

    if has_deletes {
        // Deletes don't move the state vector; compare the full encoded state
        // (which includes the delete set), before vs. after, on the same probe.
        let before = probe
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        probe
            .transact_mut()
            .apply_update(update)
            .map_err(|e| e.to_string())?;
        let after = probe
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        Ok(before != after)
    } else {
        let before = probe.transact().state_vector();
        probe
            .transact_mut()
            .apply_update(update)
            .map_err(|e| e.to_string())?;
        let after = probe.transact().state_vector();
        Ok(before != after)
    }
}

/// True if the doc holds pending structs or a pending delete set: blocks that
/// couldn't integrate because a dependency is missing. Test-only: asserts the
/// causal-chain parking behavior in the unit tests below.
#[cfg(test)]
pub(crate) fn doc_has_pending(doc: &Doc) -> bool {
    let txn = doc.transact();
    txn.store().pending_update().is_some() || txn.store().pending_ds().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::sync::Awareness;
    use yrs::updates::encoder::Encode;
    use yrs::Text;

    fn text_update(content: &str) -> Vec<u8> {
        let doc = Doc::new();
        let text = doc.get_or_insert_text("content");
        text.insert(&mut doc.transact_mut(), 0, content);
        let update = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        update
    }

    fn update_frame(content: &str) -> Vec<u8> {
        Message::Sync(SyncMessage::Update(text_update(content))).encode_v1()
    }

    fn step1_frame() -> Vec<u8> {
        Message::Sync(SyncMessage::SyncStep1(yrs::StateVector::default())).encode_v1()
    }

    fn awareness_frame(client_id: u64) -> Vec<u8> {
        let mut awareness = Awareness::new(Doc::with_client_id(client_id));
        awareness
            .set_local_state(serde_json::json!({ "user": "alice" }))
            .unwrap();
        Message::Awareness(awareness.update().unwrap()).encode_v1()
    }

    #[test]
    fn classify_accepts_clean_single_messages() {
        assert_eq!(classify_message(&step1_frame()), 1);
        assert_eq!(classify_message(&update_frame("hi")), 2);
        assert_eq!(classify_message(&awareness_frame(7)), 3);
        assert_eq!(classify_message(&Message::AwarenessQuery.encode_v1()), 4);
    }

    #[test]
    fn classify_rejects_unsafe_frames() {
        assert_eq!(classify_message(b""), 0, "empty");
        assert_eq!(classify_message(&[0xff, 0xff, 0xff]), 0, "garbage");
        assert_eq!(classify_message(&[0x63, 0x63, 0x63]), 0, "unknown type");

        let mut two = update_frame("a");
        two.extend(awareness_frame(1)); // two messages packed together
        assert_eq!(classify_message(&two), 0, "multi-message");

        let mut trailing = update_frame("a");
        trailing.extend_from_slice(&[0xde, 0xad]);
        assert_eq!(classify_message(&trailing), 0, "trailing garbage");

        let frame = update_frame("hello");
        assert_eq!(classify_message(&frame[..frame.len() / 2]), 0, "truncated");
    }

    #[test]
    fn update_advances_is_false_for_an_already_applied_retry() {
        let doc = Doc::new();
        let upd = text_update("hello");

        // Against a doc that doesn't have it yet, the update advances.
        assert!(
            update_advances_doc(&doc, &upd).unwrap(),
            "new content advances"
        );

        // Apply it, then the byte-identical retry no longer advances.
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&upd).unwrap())
            .unwrap();
        assert!(
            !update_advances_doc(&doc, &upd).unwrap(),
            "an already-applied retry does not advance"
        );

        // A genuinely new insert (from a different client) still advances.
        let more = text_update("world");
        assert!(
            update_advances_doc(&doc, &more).unwrap(),
            "different new content advances"
        );
    }

    #[test]
    fn update_advances_handles_a_dependent_diff_update() {
        // A causally-pending diff (its structs depend on content the doc already
        // has) reports an empty state_vector() in isolation, which a naive check
        // would misread as a no-op. Verify the trial-apply gets it right.
        let doc = Doc::new();
        let text = doc.get_or_insert_text("content");
        text.insert(&mut doc.transact_mut(), 0, "a");
        let a_update = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        let sv_a = doc.transact().state_vector();
        text.insert(&mut doc.transact_mut(), 1, "b");
        let diff = doc.transact().encode_state_as_update_v1(&sv_a); // depends on "a"

        // A server that has only "a".
        let server = Doc::new();
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&a_update).unwrap())
            .unwrap();

        assert!(
            update_advances_doc(&server, &diff).unwrap(),
            "a dependent diff carrying new content advances"
        );
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&diff).unwrap())
            .unwrap();
        assert!(
            !update_advances_doc(&server, &diff).unwrap(),
            "the byte-identical retry of that diff does not advance"
        );
    }

    #[test]
    fn update_advances_is_exact_for_pure_delete_retries() {
        // Build "hello", snapshot the pre-delete content, then delete a char and
        // capture just that deletion as a diff (only a delete set, no new structs).
        let doc = Doc::new();
        let text = doc.get_or_insert_text("content");
        text.insert(&mut doc.transact_mut(), 0, "hello");
        let content_state = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        let sv_before = doc.transact().state_vector();
        text.remove_range(&mut doc.transact_mut(), 0, 1); // delete "h"
        let delete = doc.transact().encode_state_as_update_v1(&sv_before);

        assert!(
            !yrs::Update::decode_v1(&delete)
                .unwrap()
                .delete_set()
                .is_empty(),
            "the diff carries a delete set"
        );

        // A server holding the pre-delete content, but not the deletion yet.
        let server = Doc::new();
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&content_state).unwrap())
            .unwrap();

        // The deletion is new: it advances (must be recorded).
        assert!(
            update_advances_doc(&server, &delete).unwrap(),
            "a not-yet-applied deletion advances the doc"
        );

        // Apply it; now the byte-identical pure-delete retry must NOT advance.
        // (This is the behavior change: it used to conservatively return true.)
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&delete).unwrap())
            .unwrap();
        assert!(
            !update_advances_doc(&server, &delete).unwrap(),
            "an already-applied pure-delete retry does not advance"
        );
    }

    #[test]
    fn update_advances_for_a_delete_bundled_with_new_content() {
        // A delete-bearing update that ALSO carries a new struct still advances,
        // even after the pure-delete part would be a no-op on its own.
        let doc = Doc::new();
        let text = doc.get_or_insert_text("content");
        text.insert(&mut doc.transact_mut(), 0, "hello");
        let content_state = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        let sv_before = doc.transact().state_vector();
        text.remove_range(&mut doc.transact_mut(), 0, 1); // delete "h"
        text.insert(&mut doc.transact_mut(), 4, "!"); // and add "!"
        let mixed = doc.transact().encode_state_as_update_v1(&sv_before);

        let server = Doc::new();
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&content_state).unwrap())
            .unwrap();
        assert!(
            update_advances_doc(&server, &mixed).unwrap(),
            "an insert+delete update advances"
        );
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&mixed).unwrap())
            .unwrap();
        assert!(
            !update_advances_doc(&server, &mixed).unwrap(),
            "its byte-identical retry does not advance"
        );
    }

    #[test]
    fn merged_doc_update_extracts_and_skips_no_ops() {
        // A document update yields a delta that reconstructs the content.
        let delta = merged_doc_update(&update_frame("hello"))
            .unwrap()
            .expect("a document update");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&delta).unwrap())
            .unwrap();
        // The delta carried real content, so applying it advances the doc.
        assert!(!doc.transact().state_vector().is_empty());

        // A SyncStep1 request carries no document change.
        assert!(merged_doc_update(&step1_frame()).unwrap().is_none());

        // An empty SyncStep2 (no new structs) is a no-op.
        let empty = Message::Sync(SyncMessage::SyncStep2(
            Doc::new()
                .transact()
                .encode_state_as_update_v1(&yrs::StateVector::default()),
        ))
        .encode_v1();
        assert!(merged_doc_update(&empty).unwrap().is_none());
    }

    #[test]
    fn merged_doc_update_merges_multiple_updates() {
        // Two updates from different clients packed in one frame merge into one.
        let mut frame = update_frame("a");
        frame.extend(update_frame("b"));
        let merged = merged_doc_update(&frame).unwrap().expect("merged update");

        // The merged update must decode cleanly as a single update.
        assert!(yrs::Update::decode_v1(&merged).is_ok());
    }

    #[test]
    fn update_readiness_and_pending_detect_a_causal_gap() {
        // Three sequential single-char inserts from one client: A, then B, then
        // C. Each delta depends on the previous, so C can't integrate without B.
        let src = Doc::new();
        let txt = src.get_or_insert_text("t");
        let mut deltas: Vec<Vec<u8>> = Vec::new();
        let mut prev = yrs::StateVector::default();
        for (i, ch) in ["A", "B", "C"].into_iter().enumerate() {
            txt.insert(&mut src.transact_mut(), i as u32, ch);
            deltas.push(src.transact().encode_state_as_update_v1(&prev));
            prev = src.transact().state_vector();
        }
        let (u1, u2, u3) = (&deltas[0], &deltas[1], &deltas[2]);

        // A doc holding only u1 (u2 was lost in transit / its record failed):
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(u1).unwrap())
            .unwrap();
        assert!(update_is_ready(&doc, u1).unwrap(), "u1 has no missing deps");
        assert!(
            !update_is_ready(&doc, u3).unwrap(),
            "u3 depends on the missing u2"
        );
        assert!(
            !doc_has_pending(&doc),
            "nothing pending until u3 is applied"
        );

        // Applying u3 anyway parks it as a pending struct.
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(u3).unwrap())
            .unwrap();
        assert!(
            doc_has_pending(&doc),
            "u3 is pending: its parent u2 is missing"
        );

        // Once u2 arrives (via resync), u3 integrates and pending clears.
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(u2).unwrap())
            .unwrap();
        assert!(!doc_has_pending(&doc), "u2 arrived; u3 integrated");
    }
}
