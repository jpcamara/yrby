// Pure protocol helpers: no Ruby, no GVL, no `unsafe`. Everything here operates
// on plain byte slices and `yrs` types, so it's unit-tested directly (see the
// `tests` module below) without a Ruby VM. The Ruby-facing wrappers in lib.rs
// copy bytes out of Ruby strings and call into these under `nogvl`.
use crate::is_safe_client_id;
use std::sync::Arc;
use yrs::encoding::read::{Cursor, Error as ReadError, Read};
use yrs::sync::protocol::{
    MessageReader, MSG_AUTH, MSG_AWARENESS, MSG_QUERY_AWARENESS, MSG_SYNC, MSG_SYNC_STEP_1,
    MSG_SYNC_STEP_2, MSG_SYNC_UPDATE, PERMISSION_DENIED,
};
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::{Decode, Decoder, DecoderV1};
use yrs::{Any, ClientID, Doc, ReadTxn, Transact, ID};

fn unsafe_client_id_error(id: u64) -> ReadError {
    ReadError::Custom(format!(
        "client_id {id} exceeds the maximum safe integer (2^53 - 1); \
         Yjs client IDs must be JS-safe integers to avoid collisions"
    ))
}

fn checked_client_id(id: u64) -> Result<ClientID, ReadError> {
    if !is_safe_client_id(id) {
        return Err(unsafe_client_id_error(id));
    }
    Ok(ClientID::new(id))
}

fn validate_raw_client_id(id: u64) -> Result<(), ReadError> {
    if !is_safe_client_id(id) {
        return Err(unsafe_client_id_error(id));
    }
    Ok(())
}

struct CheckedDecoderV1<'a> {
    cursor: Cursor<'a>,
}

impl<'a> CheckedDecoderV1<'a> {
    fn new(cursor: Cursor<'a>) -> Self {
        CheckedDecoderV1 { cursor }
    }

    fn read_id(&mut self) -> Result<ID, ReadError> {
        let client: u64 = self.read_var()?;
        validate_raw_client_id(client)?;
        let clock = self.read_var()?;
        Ok(ID::new(ClientID::new(client), clock))
    }
}

impl<'a> Read for CheckedDecoderV1<'a> {
    #[inline]
    fn read_u8(&mut self) -> Result<u8, ReadError> {
        self.cursor.read_u8()
    }

    #[inline]
    fn read_exact(&mut self, len: usize) -> Result<&[u8], ReadError> {
        self.cursor.read_exact(len)
    }
}

impl<'a> Decoder for CheckedDecoderV1<'a> {
    #[inline]
    fn reset_ds_cur_val(&mut self) {}

    #[inline]
    fn read_ds_clock(&mut self) -> Result<u32, ReadError> {
        self.read_var()
    }

    #[inline]
    fn read_ds_len(&mut self) -> Result<u32, ReadError> {
        self.read_var()
    }

    #[inline]
    fn read_left_id(&mut self) -> Result<ID, ReadError> {
        self.read_id()
    }

    #[inline]
    fn read_right_id(&mut self) -> Result<ID, ReadError> {
        self.read_id()
    }

    #[inline]
    fn read_client(&mut self) -> Result<ClientID, ReadError> {
        let client: u64 = self.cursor.read_var()?;
        checked_client_id(client)
    }

    #[inline]
    fn read_info(&mut self) -> Result<u8, ReadError> {
        self.cursor.read_u8()
    }

    #[inline]
    fn read_parent_info(&mut self) -> Result<bool, ReadError> {
        let info: u32 = self.cursor.read_var()?;
        Ok(info == 1)
    }

    #[inline]
    fn read_type_ref(&mut self) -> Result<u8, ReadError> {
        self.cursor.read_u8()
    }

    #[inline]
    fn read_len(&mut self) -> Result<u32, ReadError> {
        self.read_var()
    }

    #[inline]
    fn read_any(&mut self) -> Result<Any, ReadError> {
        Any::decode(self)
    }

    #[inline]
    fn read_json(&mut self) -> Result<Any, ReadError> {
        let src = self.read_string()?;
        Any::from_json(src)
    }

    #[inline]
    fn read_key(&mut self) -> Result<Arc<str>, ReadError> {
        let str: Arc<str> = self.read_string()?.into();
        Ok(str)
    }

    #[inline]
    fn read_to_end(&mut self) -> Result<&[u8], ReadError> {
        Ok(&self.cursor.buf[self.cursor.next..])
    }
}

pub(crate) fn validate_state_vector_client_ids(bytes: &[u8]) -> Result<(), String> {
    let mut cursor = Cursor::new(bytes);
    let len: u32 = cursor.read_var().map_err(|e| e.to_string())?;
    for _ in 0..len {
        let client: u64 = cursor.read_var().map_err(|e| e.to_string())?;
        validate_raw_client_id(client).map_err(|e| e.to_string())?;
        let _: u32 = cursor.read_var().map_err(|e| e.to_string())?;
    }
    if cursor.has_content() {
        return Err("state vector has trailing bytes".to_string());
    }
    Ok(())
}

pub(crate) fn validate_update_client_ids(update_bytes: &[u8]) -> Result<(), String> {
    let mut decoder = CheckedDecoderV1::new(Cursor::new(update_bytes));
    yrs::Update::decode(&mut decoder).map_err(|e| e.to_string())?;
    if decoder.cursor.has_content() {
        return Err("update has trailing bytes".to_string());
    }
    Ok(())
}

fn validate_awareness_update_client_ids(bytes: &[u8]) -> Result<(), String> {
    let mut cursor = Cursor::new(bytes);
    let len: u32 = cursor.read_var().map_err(|e| e.to_string())?;
    for _ in 0..len {
        let client: u64 = cursor.read_var().map_err(|e| e.to_string())?;
        validate_raw_client_id(client).map_err(|e| e.to_string())?;
        let _: u32 = cursor.read_var().map_err(|e| e.to_string())?;
        let _ = cursor.read_string().map_err(|e| e.to_string())?;
    }
    if cursor.has_content() {
        return Err("awareness update has trailing bytes".to_string());
    }
    Ok(())
}

pub(crate) fn validate_frame_client_ids(bytes: &[u8]) -> Result<(), String> {
    let mut cursor = Cursor::new(bytes);
    while cursor.has_content() {
        let tag: u8 = cursor.read_var().map_err(|e| e.to_string())?;
        match tag {
            MSG_SYNC => {
                let sync_tag: u8 = cursor.read_var().map_err(|e| e.to_string())?;
                let payload = cursor.read_buf().map_err(|e| e.to_string())?;
                match sync_tag {
                    MSG_SYNC_STEP_1 => validate_state_vector_client_ids(payload)?,
                    MSG_SYNC_STEP_2 | MSG_SYNC_UPDATE => validate_update_client_ids(payload)?,
                    _ => return Err("unknown sync message type".to_string()),
                }
            }
            MSG_AWARENESS => {
                let payload = cursor.read_buf().map_err(|e| e.to_string())?;
                validate_awareness_update_client_ids(payload)?;
            }
            MSG_AUTH => {
                let permission: u8 = cursor.read_var().map_err(|e| e.to_string())?;
                if permission == PERMISSION_DENIED {
                    let _ = cursor.read_string().map_err(|e| e.to_string())?;
                }
            }
            MSG_QUERY_AWARENESS => {}
            _ => {
                let _ = cursor.read_buf().map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(())
}

/// Classify a frame: a non-zero code only for exactly one well-formed message
/// that consumes the whole buffer (see `RbAwareness::message_kind` for codes).
pub(crate) fn classify_message(bytes: &[u8]) -> u8 {
    if validate_frame_client_ids(bytes).is_err() {
        return 0;
    }
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
    validate_frame_client_ids(bytes)?;
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
    // pending update as a no-op: since yrs 0.26 such an update reports an empty
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

/// Collect the awareness client IDs referenced by a frame's awareness messages.
pub(crate) fn awareness_client_ids_in(bytes: &[u8]) -> Result<Vec<u64>, String> {
    validate_frame_client_ids(bytes)?;
    let mut decoder = DecoderV1::new(Cursor::new(bytes));
    let mut ids = Vec::new();
    for msg in MessageReader::new(&mut decoder) {
        if let Message::Awareness(update) = msg.map_err(|e| e.to_string())? {
            ids.extend(update.clients.keys().map(|c| c.get()));
        }
    }
    Ok(ids)
}

/// True if applying `update_bytes` to `doc` would integrate cleanly: every
/// dependency the update references is already present (the doc's state vector
/// covers the update's lower bound). A pure read; does not mutate the doc.
/// When false, applying it would park a pending struct -- the signal that an
/// earlier, causally-prior update is missing.
pub(crate) fn update_is_ready(doc: &Doc, update_bytes: &[u8]) -> Result<bool, String> {
    validate_update_client_ids(update_bytes)?;
    let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;
    Ok(doc.transact().state_vector() >= update.state_vector_lower())
}

/// True if applying `update_bytes` would actually change `doc` -- i.e. it carries
/// content the doc doesn't already have. Lets the server make durable side
/// effects exactly-once: a lost-ack retry re-sends an update the server already
/// applied; that retry is causally ready (so `update_is_ready` is true) but must
/// NOT re-run `on_change`.
///
/// We can't read the update's own state vector to decide this: yrs reports an
/// EMPTY state_vector() for a causally-pending diff (e.g. a resync delta whose
/// structs depend on updates the doc has but the standalone update doesn't),
/// which would look identical to a no-op. So measure the real effect: seed an
/// independent probe with the doc's current state, apply the update there, and
/// see whether the state vector grew. Deletes don't move the state vector, so we
/// can't cheaply prove a delete-bearing update is a duplicate -- we
/// conservatively report it as advancing (record it). That can still
/// double-record a pure-delete retry, but it NEVER drops a real deletion, which
/// is the safe direction. Assumes the update is already causally ready.
pub(crate) fn update_advances_doc(doc: &Doc, update_bytes: &[u8]) -> Result<bool, String> {
    validate_update_client_ids(update_bytes)?;
    let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;
    if !update.delete_set().is_empty() {
        return Ok(true); // can't cheaply prove a delete is a duplicate; record it
    }
    let probe = Doc::new();
    let current = doc
        .transact()
        .encode_state_as_update_v1(&yrs::StateVector::default());
    probe
        .transact_mut()
        .apply_update(yrs::Update::decode_v1(&current).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let before = probe.transact().state_vector();
    probe
        .transact_mut()
        .apply_update(update)
        .map_err(|e| e.to_string())?;
    let after = probe.transact().state_vector();
    Ok(after != before)
}

/// True if the doc holds pending structs or a pending delete set -- blocks that
/// couldn't integrate because a dependency is missing. Used as a backstop after
/// loading from storage: leftover pending means the stored log has a causal gap.
pub(crate) fn doc_has_pending(doc: &Doc) -> bool {
    let txn = doc.transact();
    txn.store().pending_update().is_some() || txn.store().pending_ds().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::is_safe_client_id;
    use yrs::encoding::write::Write;
    use yrs::sync::Awareness;
    use yrs::updates::encoder::{Encode, Encoder, EncoderV1};
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

    fn unsafe_struct_client_update() -> Vec<u8> {
        let mut update = EncoderV1::new();
        update.write_var(1u32); // client count
        update.write_var(0u32); // block count for this client
        update.write_var(1u64 << 53); // unsafe client id
        update.write_var(0u32); // clock
        update.write_var(0u32); // delete-set client count
        update.to_vec()
    }

    fn unsafe_awareness_frame() -> Vec<u8> {
        let mut payload = EncoderV1::new();
        payload.write_var(1u32); // client count
        payload.write_var(1u64 << 53); // unsafe client id
        payload.write_var(1u32); // clock
        payload.write_string("{}");

        let mut frame = EncoderV1::new();
        frame.write_var(MSG_AWARENESS);
        frame.write_buf(payload.to_vec());
        frame.to_vec()
    }

    fn unsafe_step1_frame() -> Vec<u8> {
        let mut sv = EncoderV1::new();
        sv.write_var(1u32); // state-vector entry count
        sv.write_var(1u64 << 53); // unsafe client id
        sv.write_var(0u32); // clock

        let mut frame = EncoderV1::new();
        frame.write_var(MSG_SYNC);
        frame.write_var(MSG_SYNC_STEP_1);
        frame.write_buf(sv.to_vec());
        frame.to_vec()
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
        // has) reports an EMPTY state_vector() in isolation -- a naive check would
        // misread it as a no-op. Verify the trial-apply gets it right.
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
    fn client_id_safe_integer_boundary() {
        assert!(is_safe_client_id(0), "zero is fine");
        assert!(
            is_safe_client_id((1 << 53) - 1),
            "2^53 - 1 is the max safe id"
        );
        assert!(!is_safe_client_id(1 << 53), "2^53 is unsafe");
        assert!(!is_safe_client_id(1 << 63), "2^63 is unsafe");
        assert!(!is_safe_client_id(u64::MAX), "u64::MAX is unsafe");
    }

    #[test]
    fn wire_client_id_validation_rejects_unsafe_sync_update_clients() {
        let update = unsafe_struct_client_update();
        assert!(
            validate_update_client_ids(&update).is_err(),
            "raw unsafe update client id is rejected before yrs can mask it"
        );

        let frame = Message::Sync(SyncMessage::Update(update)).encode_v1();
        assert_eq!(
            classify_message(&frame),
            0,
            "unsafe sync frame is not relayable"
        );
        assert!(merged_doc_update(&frame).is_err());
    }

    #[test]
    fn wire_client_id_validation_rejects_unsafe_awareness_and_step1_clients() {
        assert!(
            validate_frame_client_ids(&unsafe_awareness_frame()).is_err(),
            "raw unsafe awareness client id is rejected"
        );
        assert_eq!(classify_message(&unsafe_awareness_frame()), 0);
        assert!(awareness_client_ids_in(&unsafe_awareness_frame()).is_err());

        assert!(
            validate_frame_client_ids(&unsafe_step1_frame()).is_err(),
            "raw unsafe state-vector client id is rejected"
        );
        assert_eq!(classify_message(&unsafe_step1_frame()), 0);
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
    fn awareness_client_ids_are_collected() {
        assert_eq!(
            awareness_client_ids_in(&awareness_frame(111)).unwrap(),
            vec![111]
        );
        // A document frame has no awareness client ids.
        assert!(awareness_client_ids_in(&update_frame("x"))
            .unwrap()
            .is_empty());
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
