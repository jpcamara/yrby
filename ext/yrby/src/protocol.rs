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
use yrs::updates::encoder::Encode;
use yrs::{StateVector, Update};

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

fn decode_sv(sv: &[u8]) -> Result<StateVector, String> {
    if sv.is_empty() {
        return Ok(StateVector::default());
    }
    StateVector::decode_v1(sv).map_err(|e| e.to_string())
}

/// What `update` holds that a peer at `sv` lacks: the structs past `sv`
/// and the whole delete set (deletes don't move a state vector, so a peer
/// can be missing one at any `sv`), as Yjs's diffUpdate. Works on the
/// update's bytes, without integrating it into a doc.
pub(crate) fn diff_update(update: &[u8], sv: &[u8]) -> Result<Vec<u8>, String> {
    let sv = decode_sv(sv)?.encode_v1();
    yrs::diff_updates_v1(update, &sv).map_err(|e| e.to_string())
}

/// The state vector of a document stored as `update`, read from the
/// update's structs without integrating them.
pub(crate) fn state_vector_of(update: &[u8]) -> Result<Vec<u8>, String> {
    yrs::encode_state_vector_from_update_v1(update).map_err(|e| e.to_string())
}

/// `sv` advanced by what `updates` add contiguously after it, per client.
/// With `sv` the state vector of a stored snapshot and `updates` the log
/// since, this is the state vector of snapshot plus log without reading the
/// snapshot. It stops at a client's first missing clock, so it can be lower
/// than the merged document's (a peer then sends something twice), never
/// higher.
pub(crate) fn extend_state_vector(sv: &[u8], updates: &[Vec<u8>]) -> Result<Vec<u8>, String> {
    let mut out = decode_sv(sv)?;
    let mut ranges: std::collections::HashMap<yrs::ClientID, Vec<std::ops::Range<u32>>> =
        std::collections::HashMap::new();
    for bytes in updates.iter().filter(|b| !b.is_empty()) {
        let update = Update::decode_v1(bytes).map_err(|e| e.to_string())?;
        for (client, rs) in update.insertions(true).iter() {
            ranges
                .entry(*client)
                .or_default()
                .extend(rs.iter().cloned());
        }
    }
    for (client, mut rs) in ranges {
        rs.sort_by_key(|r| r.start);
        let mut clock = out.get(&client);
        for r in rs {
            if r.start > clock {
                break;
            }
            clock = clock.max(r.end);
        }
        out.set_max(client, clock);
    }
    Ok(out.encode_v1())
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::sync::Awareness;
    use yrs::{Doc, GetString, ReadTxn, Text, Transact};

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
    fn diff_update_and_extend_state_vector_work_from_update_bytes() {
        let source = Doc::new();
        let text = source.get_or_insert_text("content");
        text.insert(&mut source.transact_mut(), 0, "abc");
        let snapshot = source
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        let snapshot_sv = source.transact().state_vector().encode_v1();
        assert_eq!(state_vector_of(&snapshot).unwrap(), snapshot_sv);

        let sv = source.transact().state_vector();
        text.insert(&mut source.transact_mut(), 3, "d");
        let first = source.transact().encode_state_as_update_v1(&sv);
        let sv = source.transact().state_vector();
        text.insert(&mut source.transact_mut(), 4, "e");
        let second = source.transact().encode_state_as_update_v1(&sv);
        let full_sv = source.transact().state_vector().encode_v1();

        // In either order the tail extends the snapshot's vector to the full one.
        for tail in [
            vec![first.clone(), second.clone()],
            vec![second.clone(), first.clone()],
        ] {
            assert_eq!(extend_state_vector(&snapshot_sv, &tail).unwrap(), full_sv);
        }
        // A tail missing its first update stops at the gap.
        assert_eq!(
            extend_state_vector(&snapshot_sv, &[second.clone()]).unwrap(),
            snapshot_sv
        );
        assert_eq!(extend_state_vector(b"", &[]).unwrap(), vec![0]);

        // The diff for a peer at nothing is the whole snapshot; for a peer
        // holding the snapshot's structs it still carries the delete set.
        text.remove_range(&mut source.transact_mut(), 0, 1);
        let with_delete = source
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        let peer = Doc::new();
        peer.transact_mut()
            .apply_update(Update::decode_v1(&snapshot).unwrap())
            .unwrap();
        peer.transact_mut()
            .apply_update(Update::decode_v1(&first).unwrap())
            .unwrap();
        peer.transact_mut()
            .apply_update(Update::decode_v1(&second).unwrap())
            .unwrap();
        let peer_sv = peer.transact().state_vector().encode_v1();
        assert_eq!(peer_sv, full_sv, "the delete didn't move the vector");
        let diff = diff_update(&with_delete, &peer_sv).unwrap();
        peer.transact_mut()
            .apply_update(Update::decode_v1(&diff).unwrap())
            .unwrap();
        let read = |d: &Doc| d.get_or_insert_text("content").get_string(&d.transact());
        assert_eq!(read(&peer), "bcde");

        let fresh = Doc::new();
        fresh
            .transact_mut()
            .apply_update(Update::decode_v1(&diff_update(&with_delete, b"").unwrap()).unwrap())
            .unwrap();
        assert_eq!(read(&fresh), "bcde");
    }
}
