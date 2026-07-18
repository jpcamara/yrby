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
use yrs::{Doc, ReadTxn, StateVector, Transact, Update, WriteTxn};

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

/// True if applying `update_bytes` to `doc` would integrate cleanly; false if
/// it would park as pending (a causally-prior update is missing). A pure read.
///
/// This must be EXACT: the sync layer records on "ready" and resyncs on "not
/// ready", and a parked update that slipped through would look like an
/// already-applied retry downstream — acked and dropped, losing real content.
///
/// Clocks alone can't decide it. An update can satisfy every per-client clock
/// and still fail to integrate: its items may reference other clients' blocks
/// (origins/parents), and merged updates hide internal gaps behind Skip blocks.
/// So the clock lower bound serves only as a cheap definitive REJECT; "ready"
/// is decided by trial-integrating on a throwaway probe seeded with the doc's
/// integrated state — ready iff nothing parks.
pub(crate) fn update_is_ready(doc: &Doc, update_bytes: &[u8]) -> Result<bool, String> {
    let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;
    // Partial order: "not covered" includes incomparable — not ready either way.
    let lower_covered = doc.transact().state_vector() >= update.state_vector_lower();
    if !lower_covered {
        return Ok(false);
    }
    // Seed the probe with the doc's INTEGRATED state (gap-free), for two
    // reasons. A lossless seed would replant the doc's own pre-existing
    // pending in the probe, making has_pending true for EVERY update — the
    // verdict must be about this update, not the doc's baggage. And an update
    // whose dependency exists only in that pending buffer is genuinely not
    // ready: recording it would put a gap in the durable log; a resync heals
    // both it and the pending it leans on as one complete delta.
    let seed = integrated_update(doc, &StateVector::default())?;
    let probe = Doc::new();
    {
        let mut txn = probe.transact_mut();
        txn.apply_update(Update::decode_v1(&seed).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        txn.apply_update(update).map_err(|e| e.to_string())?;
    }
    Ok(!has_pending(&probe))
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

    // Fast path: blocks beyond the doc's state vector are content the doc
    // lacks — the update advances, no probe needed. The common case (a novel
    // edit) exits here; only retries and ambiguous diffs pay for the probe.
    if !has_deletes {
        let covered = doc.transact().state_vector() >= update.state_vector();
        if !covered {
            return Ok(true);
        }
    }

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
    let pending_before = {
        probe.transact().store().pending_update().is_some()
            || probe.transact().store().pending_ds().is_some()
    };

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
        if before != after {
            return Ok(true);
        }
        // An unchanged state vector is ambiguous. Usually it means the doc
        // already had everything in this update (a retry — return false, don't
        // re-record). But it can ALSO mean the update failed to integrate and
        // was stashed as pending, which doesn't move the state vector either.
        // That case is missing content, not a duplicate — returning false would
        // let a caller ack it and drop it. Distinguish the two by whether the
        // probe gained pending. (The sync flow screens gaps out with
        // update_is_ready before calling this; the check guards direct callers.)
        let pending_after = probe.transact().store().pending_update().is_some()
            || probe.transact().store().pending_ds().is_some();
        Ok(pending_after != pending_before)
    }
}

/// True if applying `update` would add any content the doc doesn't already hold
/// — whether that content integrates or parks as a pending struct.
///
/// The gap-tolerant sibling of `update_advances_doc`. `update_advances` answers
/// "does the *integrated* state move forward?", which is false for a second
/// gappy update on an already-pending doc (the pending flag is already set and
/// the state vector doesn't move) — so a caller storing gappy updates would
/// misread that new gap as a duplicate and drop it. This compares the doc's full
/// lossless encoding (which includes pending) before and after applying, on a
/// throwaway copy, so a newly-parked pending struct counts as added content.
/// Pure read; does not mutate `doc`.
pub(crate) fn update_adds_content_doc(doc: &Doc, update_bytes: &[u8]) -> Result<bool, String> {
    let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;

    // Seed a probe with the doc's current full state (pending included), so we
    // measure the update's effect without mutating the real doc.
    let probe = Doc::new();
    let current = doc
        .transact()
        .encode_state_as_update_v1(&yrs::StateVector::default());
    probe
        .transact_mut()
        .apply_update(yrs::Update::decode_v1(&current).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;

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
}

/// True if the doc holds un-integrable pending structs or a pending delete set:
/// blocks that couldn't integrate because a causally-prior update is missing. A
/// pure read; does not mutate.
pub(crate) fn has_pending(doc: &Doc) -> bool {
    let txn = doc.transact();
    txn.store().pending_update().is_some() || txn.store().pending_ds().is_some()
}

/// Encode the doc's **integrated** state as a v1 update diffed against `sv`,
/// excluding any pending (un-integrable) structs and pending delete set.
///
/// Pending blocks are a recovery buffer, not document state. Serving them across
/// the sync boundary hands a peer content it can't integrate, so the peer parks
/// the same pending forever and the state-vector/content mismatch drives endless
/// resync traffic. `encode_state_as_update_v1` merges pending back in (see yrs
/// `merge_pending_v1`), so to get a gap-free encode we rebuild the state into a
/// throwaway doc and `prune_pending` there before re-encoding.
///
/// Non-destructive: the prune happens only on the throwaway copy; `doc` keeps its
/// pending, so a genuine gap still heals if its missing dependency later arrives.
pub(crate) fn integrated_update(doc: &Doc, sv: &StateVector) -> Result<Vec<u8>, String> {
    // Pending check and encode share ONE transaction — with two, a concurrent
    // gappy apply_update could slip between them and the encode would serve
    // the very pending this function exists to exclude.
    let full = {
        let txn = doc.transact();
        let store = txn.store();
        // Nothing pending: the direct encode is already gap-free.
        if store.pending_update().is_none() && store.pending_ds().is_none() {
            return Ok(txn.encode_state_as_update_v1(sv));
        }
        txn.encode_state_as_update_v1(&StateVector::default())
    };
    let clean = Doc::new();
    {
        let mut txn = clean.transact_mut();
        txn.apply_update(Update::decode_v1(&full).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        txn.prune_pending();
    }
    let out = clean.transact().encode_state_as_update_v1(sv);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::sync::Awareness;
    use yrs::updates::encoder::Encode;
    use yrs::{GetString, Text};

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
        assert!(!has_pending(&doc), "nothing pending until u3 is applied");

        // Applying u3 anyway parks it as a pending struct.
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(u3).unwrap())
            .unwrap();
        assert!(has_pending(&doc), "u3 is pending: its parent u2 is missing");

        // Once u2 arrives (via resync), u3 integrates and pending clears.
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(u2).unwrap())
            .unwrap();
        assert!(!has_pending(&doc), "u2 arrived; u3 integrated");
    }

    // Build a cross-client-origin gap: client C creates "abc"; client A applies
    // it and types between C's characters, so A's delta references C's blocks as
    // origins. Returns (c_update, a_delta). On a doc missing `c_update`, the
    // per-client clock lower bound of `a_delta` is satisfied (A starts at clock
    // 0) but integration parks — the case a clock-only readiness check misses.
    fn cross_client_origin_gap() -> (Vec<u8>, Vec<u8>) {
        let c = Doc::new();
        let ct = c.get_or_insert_text("t");
        ct.insert(&mut c.transact_mut(), 0, "abc");
        let c_update = c
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());

        let a = Doc::new();
        a.transact_mut()
            .apply_update(yrs::Update::decode_v1(&c_update).unwrap())
            .unwrap();
        let sv_before = a.transact().state_vector();
        let at = a.get_or_insert_text("t");
        at.insert(&mut a.transact_mut(), 1, "X"); // between C's chars
        let a_delta = a.transact().encode_state_as_update_v1(&sv_before);
        (c_update, a_delta)
    }

    #[test]
    fn cross_client_origin_gap_is_not_ready() {
        let (c_update, a_delta) = cross_client_origin_gap();

        // A server that never saw C's content: the clock lower bound passes, but
        // the update can't integrate — it must NOT be ready (previously it was,
        // and the downstream advances? probe then acked-and-dropped it).
        let server = Doc::new();
        assert!(
            !update_is_ready(&server, &a_delta).unwrap(),
            "a delta with unmet cross-client origins is not ready"
        );

        // Once the server has C's content, the same delta is ready and advances.
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&c_update).unwrap())
            .unwrap();
        assert!(update_is_ready(&server, &a_delta).unwrap());
        assert!(update_advances_doc(&server, &a_delta).unwrap());
    }

    #[test]
    fn merged_update_with_internal_skip_gap_is_not_ready() {
        // Merging u1 and u3 (u2 missing) yields one update with a Skip block; its
        // clock lower bound is u1's start, but the post-Skip blocks can't
        // integrate on a doc that lacks u2.
        let src = Doc::new();
        let txt = src.get_or_insert_text("t");
        let mut deltas: Vec<Vec<u8>> = Vec::new();
        let mut prev = yrs::StateVector::default();
        for (i, ch) in ["A", "B", "C"].into_iter().enumerate() {
            txt.insert(&mut src.transact_mut(), i as u32, ch);
            deltas.push(src.transact().encode_state_as_update_v1(&prev));
            prev = src.transact().state_vector();
        }
        let merged = yrs::merge_updates_v1([deltas[0].as_slice(), deltas[2].as_slice()]).unwrap();

        let server = Doc::new();
        assert!(
            !update_is_ready(&server, &merged).unwrap(),
            "the post-Skip blocks depend on the missing u2"
        );
    }

    #[test]
    fn a_doc_with_legacy_pending_still_accepts_healthy_updates() {
        // Why update_is_ready seeds its probe with the INTEGRATED state: with a
        // lossless seed, the doc's own pre-existing pending would park in the
        // probe and every verdict would come back "not ready" — a server with
        // one legacy gap would reject every healthy keystroke forever.
        let (_first, dependent) = gap_pair();
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&dependent).unwrap())
            .unwrap();
        assert!(has_pending(&doc), "the doc carries a legacy parked gap");

        // A healthy, self-contained update from an unrelated client.
        let healthy = {
            let d = Doc::new();
            let t = d.get_or_insert_text("other");
            t.insert(&mut d.transact_mut(), 0, "hello");
            let txn = d.transact();
            txn.encode_state_as_update_v1(&yrs::StateVector::default())
        };

        assert!(
            update_is_ready(&doc, &healthy).unwrap(),
            "legacy pending must not veto unrelated healthy updates"
        );
        assert!(update_advances_doc(&doc, &healthy).unwrap());
    }

    #[test]
    fn an_update_depending_only_on_pending_content_is_not_ready() {
        // The other half of the integrated-only seed: a dependency that exists
        // solely in the doc's pending buffer doesn't count — recording such an
        // update would put a gap in the durable log. Not ready; resync heals
        // both as one complete delta.
        let src = Doc::new();
        let txt = src.get_or_insert_text("t");
        let mut deltas: Vec<Vec<u8>> = Vec::new();
        let mut prev = yrs::StateVector::default();
        for (i, ch) in ["A", "B", "C"].into_iter().enumerate() {
            txt.insert(&mut src.transact_mut(), i as u32, ch);
            deltas.push(src.transact().encode_state_as_update_v1(&prev));
            prev = src.transact().state_vector();
        }

        // The doc holds u2 only as PENDING (u1 never arrived); u3 depends on u2.
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&deltas[1]).unwrap())
            .unwrap();
        assert!(has_pending(&doc), "u2 parked without u1");

        assert!(
            !update_is_ready(&doc, &deltas[2]).unwrap(),
            "a dependency satisfied only by pending content is not ready"
        );
    }

    #[test]
    fn update_advances_reports_true_when_the_update_would_park() {
        // Defense in depth for callers using advances? without the ready gate: a
        // gappy update parks pending — that changes the doc, so it advances (it
        // must never be misread as an already-applied retry and dropped).
        let (_c_update, a_delta) = cross_client_origin_gap();
        let server = Doc::new();
        assert!(
            update_advances_doc(&server, &a_delta).unwrap(),
            "a parked update is not a duplicate"
        );
    }

    // Build a causal gap: `first` inserts "a", `dependent` inserts "b" after it,
    // so `dependent` alone parks as pending on a doc that lacks `first`.
    fn gap_pair() -> (Vec<u8>, Vec<u8>) {
        let src = Doc::new();
        let txt = src.get_or_insert_text("notepad");
        txt.insert(&mut src.transact_mut(), 0, "a");
        let first = src
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        let sv = src.transact().state_vector();
        txt.insert(&mut src.transact_mut(), 1, "b");
        let dependent = src.transact().encode_state_as_update_v1(&sv);
        (first, dependent)
    }

    #[test]
    fn integrated_update_strips_pending_and_is_non_destructive() {
        let (_first, dependent) = gap_pair();
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&dependent).unwrap())
            .unwrap();
        assert!(has_pending(&doc), "the gappy update parked as pending");

        // encode_state_as_update carries the pending; integrated_update does not.
        let full = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        let gap_free = integrated_update(&doc, &yrs::StateVector::default()).unwrap();
        assert_ne!(full, gap_free, "integrated_update drops the pending bytes");

        // Applying the gap-free encode to a fresh peer must NOT poison it.
        let peer = Doc::new();
        peer.transact_mut()
            .apply_update(yrs::Update::decode_v1(&gap_free).unwrap())
            .unwrap();
        assert!(
            !has_pending(&peer),
            "peer got no pending from the gap-free state"
        );

        // Non-destructive: the source doc keeps its pending (so it can still heal).
        assert!(
            has_pending(&doc),
            "integrated_update did not mutate the source"
        );
    }

    #[test]
    fn integrated_update_fast_path_matches_direct_encode_when_clean() {
        // No pending -> byte-identical to encode_state_as_update (zero-copy path).
        let (first, _dependent) = gap_pair();
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&first).unwrap())
            .unwrap();
        assert!(!has_pending(&doc));
        let direct = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        let via = integrated_update(&doc, &yrs::StateVector::default()).unwrap();
        assert_eq!(direct, via);
    }

    #[test]
    fn a_healed_gap_serves_its_content() {
        // After the missing dependency arrives, the (formerly pending) content is
        // integrated and integrated_update includes it.
        let (first, dependent) = gap_pair();
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&dependent).unwrap())
            .unwrap();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&first).unwrap())
            .unwrap();
        assert!(!has_pending(&doc), "gap healed once first arrived");
        let gap_free = integrated_update(&doc, &yrs::StateVector::default()).unwrap();
        let peer = Doc::new();
        peer.transact_mut()
            .apply_update(yrs::Update::decode_v1(&gap_free).unwrap())
            .unwrap();
        assert_eq!(
            peer.get_or_insert_text("notepad")
                .get_string(&peer.transact()),
            "ab"
        );
    }

    // A gappy insert from its own independent client: inserts two chars and
    // returns only the second delta, which depends on the (missing) first.
    fn independent_gappy_insert() -> Vec<u8> {
        let src = Doc::new();
        let txt = src.get_or_insert_text("notepad");
        txt.insert(&mut src.transact_mut(), 0, "x");
        let sv = src.transact().state_vector();
        txt.insert(&mut src.transact_mut(), 1, "y");
        let txn = src.transact();
        txn.encode_state_as_update_v1(&sv)
    }

    #[test]
    fn integrated_update_keeps_content_and_drops_pending_when_mixed() {
        // The realistic case: a doc with real integrated content AND a pending
        // struct. Pruning must keep the content and drop only the pending.
        let (first, _dep) = gap_pair();
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&first).unwrap())
            .unwrap(); // integrated "a"
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&independent_gappy_insert()).unwrap())
            .unwrap(); // + a pending struct from another client
        assert!(has_pending(&doc));

        let gap_free = integrated_update(&doc, &yrs::StateVector::default()).unwrap();
        let peer = Doc::new();
        peer.transact_mut()
            .apply_update(yrs::Update::decode_v1(&gap_free).unwrap())
            .unwrap();
        assert_eq!(
            peer.get_or_insert_text("notepad")
                .get_string(&peer.transact()),
            "a",
            "kept the integrated content"
        );
        assert!(!has_pending(&peer), "dropped the pending");
    }

    #[test]
    fn integrated_update_diffs_against_a_peer_sv_and_excludes_pending() {
        // The production signature: `handle_sync_message` calls
        // integrated_update(doc, peer_sv). A peer already holding the integrated
        // content should get a diff carrying no new content and no pending.
        let (first, _dep) = gap_pair();
        let server = Doc::new();
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&first).unwrap())
            .unwrap();
        server
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&independent_gappy_insert()).unwrap())
            .unwrap();

        let peer = Doc::new();
        peer.transact_mut()
            .apply_update(yrs::Update::decode_v1(&first).unwrap())
            .unwrap();
        let peer_sv = peer.transact().state_vector();

        let diff = integrated_update(&server, &peer_sv).unwrap();
        peer.transact_mut()
            .apply_update(yrs::Update::decode_v1(&diff).unwrap())
            .unwrap();
        assert_eq!(
            peer.get_or_insert_text("notepad")
                .get_string(&peer.transact()),
            "a"
        );
        assert!(!has_pending(&peer), "the diff carried no pending");
    }

    #[test]
    fn integrated_update_never_serves_pending_under_concurrent_gappy_applies() {
        // Invariant under contention: while a writer parks and heals a gappy
        // update in a loop, every integrated_update encode must be pending-free
        // for a fresh peer.
        //
        // Scope: this can't hit the original check-vs-encode race (its window
        // is nanoseconds; never reproduced even at 20k iterations) — that fix
        // is guaranteed by using a single transaction. What this catches is
        // coarser: encoding outside the lock, or a fast path skipping the
        // pending check.
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc as StdArc;

        let (first, dependent) = gap_pair();
        let doc = StdArc::new(Doc::new());
        let stop = StdArc::new(AtomicBool::new(false));

        let writer = {
            let doc = StdArc::clone(&doc);
            let stop = StdArc::clone(&stop);
            let dependent = dependent.clone();
            let first = first.clone();
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    // Park a pending struct, then heal it, over and over — the
                    // encode below keeps racing both transitions.
                    doc.transact_mut()
                        .apply_update(yrs::Update::decode_v1(&dependent).unwrap())
                        .unwrap();
                    doc.transact_mut()
                        .apply_update(yrs::Update::decode_v1(&first).unwrap())
                        .unwrap();
                }
            })
        };

        for _ in 0..500 {
            let encoded = integrated_update(&doc, &yrs::StateVector::default()).unwrap();
            let peer = Doc::new();
            peer.transact_mut()
                .apply_update(yrs::Update::decode_v1(&encoded).unwrap())
                .unwrap();
            assert!(
                !has_pending(&peer),
                "an integrated_update encode leaked pending to a peer"
            );
        }
        stop.store(true, Ordering::Relaxed);
        writer.join().unwrap();
    }

    #[test]
    fn integrated_update_strips_a_pending_delete_set() {
        // A deletion whose target struct is absent parks as a pending *delete
        // set* -- the delete-side counterpart to a pending struct.
        let src = Doc::new();
        let txt = src.get_or_insert_text("notepad");
        txt.insert(&mut src.transact_mut(), 0, "z");
        let sv = src.transact().state_vector();
        txt.remove_range(&mut src.transact_mut(), 0, 1);
        let deletion = src.transact().encode_state_as_update_v1(&sv); // delete-only

        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&deletion).unwrap())
            .unwrap();
        assert!(
            has_pending(&doc),
            "the orphan deletion parked as a pending delete set"
        );

        let gap_free = integrated_update(&doc, &yrs::StateVector::default()).unwrap();
        let peer = Doc::new();
        peer.transact_mut()
            .apply_update(yrs::Update::decode_v1(&gap_free).unwrap())
            .unwrap();
        assert!(!has_pending(&peer), "the pending delete set was not served");
        assert!(
            has_pending(&doc),
            "non-destructive: source keeps its pending"
        );
    }

    #[test]
    fn update_adds_content_sees_a_second_gap_on_an_already_pending_doc() {
        // The case update_advances_doc gets wrong: a doc already holds a pending
        // struct, and a *second, distinct* gappy update arrives. Its content is
        // new, but the integrated state vector doesn't move and the pending flag
        // is already set — so update_advances_doc reports "no advance", which a
        // gap-storing caller would misread as a duplicate and drop.
        let (_first, dependent) = gap_pair();
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&dependent).unwrap())
            .unwrap();
        assert!(has_pending(&doc), "the doc already holds a pending struct");

        let second_gap = independent_gappy_insert(); // a distinct client's gappy delta

        assert!(
            !update_advances_doc(&doc, &second_gap).unwrap(),
            "update_advances is fooled: it reports no advance for the second gap"
        );
        assert!(
            update_adds_content_doc(&doc, &second_gap).unwrap(),
            "update_adds_content sees the second gap as new content to store"
        );
    }

    #[test]
    fn update_adds_content_is_false_for_a_duplicate() {
        // A true duplicate — integrated or still-pending — adds nothing.
        let (first, dependent) = gap_pair();

        let integrated = Doc::new();
        integrated
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&first).unwrap())
            .unwrap();
        assert!(
            !update_adds_content_doc(&integrated, &first).unwrap(),
            "re-applying integrated content adds nothing"
        );

        let pending = Doc::new();
        pending
            .transact_mut()
            .apply_update(yrs::Update::decode_v1(&dependent).unwrap())
            .unwrap();
        assert!(
            !update_adds_content_doc(&pending, &dependent).unwrap(),
            "re-applying an already-pending gap adds nothing"
        );
    }

    #[test]
    fn update_adds_content_does_not_mutate_the_doc() {
        let (_first, dependent) = gap_pair();
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(yrs::Update::decode_v1(&dependent).unwrap())
            .unwrap();
        let before = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());

        update_adds_content_doc(&doc, &independent_gappy_insert()).unwrap();

        let after = doc
            .transact()
            .encode_state_as_update_v1(&yrs::StateVector::default());
        assert_eq!(before, after, "the probe must not touch the real doc");
    }
}
