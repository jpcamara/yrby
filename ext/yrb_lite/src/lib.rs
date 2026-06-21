use magnus::{
    function, method, prelude::*, Error, ExceptionClass, RString, Ruby, TryConvert, Value,
};
use std::sync::Mutex;
use yrs::encoding::read::{Cursor, Read};
use yrs::sync::protocol::MessageReader;
use yrs::sync::{Awareness, DefaultProtocol, Message, Protocol, SyncMessage};
use yrs::updates::decoder::{Decode, DecoderV1};
use yrs::updates::encoder::{Encode, Encoder, EncoderV1};
use yrs::{ClientID, Doc, ReadTxn, Transact};

/// Wrapper around yrs Doc.
///
/// Thread safety: `yrs::Doc` is `Send + Sync`. Its `transact()`/`transact_mut()`
/// acquire an internal RwLock with blocking semantics, so concurrent access from
/// multiple Ruby threads serializes safely instead of panicking. There's no
/// interior-mutability wrapper (RefCell and friends): every method opens and
/// closes its transaction within a single call.
#[magnus::wrap(class = "YrbLite::Doc", free_immediately, size)]
struct RbDoc(Doc);

/// Wrapper around yrs Awareness (which contains a Doc).
///
/// Thread safety: as of yrs 0.27 `Awareness` dropped its internal locking and
/// its mutating methods (`handle`, `set_local_state`, `clean_local_state`,
/// `remove_state`, `update_with_clients`) take `&mut self`. It is `Send` but no
/// longer `Sync`, so we serialize all access through a `Mutex`.
///
/// CRITICAL: the `Mutex` is ALWAYS locked inside the `nogvl` closure (never with
/// the GVL held) and the guard is dropped before the closure returns. This obeys
/// the same rule as the doc's RwLock (see `nogvl`): a thread never waits on this
/// lock while holding the GVL, and never reacquires the GVL while holding this
/// lock, so the GVL and this `Mutex` can't deadlock on lock order. Locking with
/// the GVL held (outside `nogvl`) reintroduces that deadlock -- don't.
///
/// For doc-only reads we clone the (Arc-backed) `Doc` out under the brief lock
/// and operate on the owned clone, so a long encode holds only the doc's own
/// RwLock, not this `Mutex`, and never blocks presence updates on another
/// thread. Lock order is always Mutex-then-doc-RwLock (or doc-RwLock alone),
/// never the reverse.
#[magnus::wrap(class = "YrbLite::Awareness", free_immediately, size)]
struct RbAwareness(Mutex<Awareness>);

/// Compile-time proof that the wrapped types are thread-safe. If a future
/// yrs upgrade makes Doc lose Send/Sync, or Awareness lose Send, this fails the
/// build instead of silently shipping a thread-unsafe gem. (Awareness is no
/// longer `Sync` as of yrs 0.27, hence the `Mutex` wrapper, which restores it.)
#[allow(dead_code)]
fn assert_thread_safe() {
    fn is_send_sync<T: Send + Sync>() {}
    is_send_sync::<Doc>();
    is_send_sync::<Mutex<Awareness>>();
}

/// Run `f` with the GVL (Global VM Lock) released, so other Ruby threads,
/// including ones calling into this extension, can run in parallel.
///
/// Safety rules for the closure:
/// - It must not touch any Ruby object or call any Ruby API. Inputs are copied
///   out of Ruby strings before entering, and results are converted to Ruby
///   objects after returning.
/// - It must be `Send` (it runs while other threads own the GVL). `&Doc` and
///   `&Mutex<Awareness>` are fine: both are `Sync` (asserted above).
/// - LOCK DISCIPLINE: any native lock it takes -- the doc's internal RwLock OR
///   the awareness `Mutex` (`self.0.lock()`) -- must be acquired AND released
///   inside this closure (GVL already dropped). Never lock with the GVL held
///   (e.g. before calling `nogvl`), or a thread waiting on the lock while
///   holding the GVL can deadlock against the GVL reacquire. Same reason we
///   never hold a lock across the GVL boundary.
///
/// Panics inside the closure are caught and re-raised (resumed) after the GVL
/// is reacquired, where magnus converts them to Ruby exceptions.
fn nogvl<F, R>(f: F) -> R
where
    F: FnOnce() -> R + Send,
    R: Send,
{
    use std::ffi::c_void;
    use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};

    struct Ctx<F, R> {
        func: Option<F>,
        result: Option<std::thread::Result<R>>,
    }

    unsafe extern "C" fn callback<F, R>(arg: *mut c_void) -> *mut c_void
    where
        F: FnOnce() -> R,
    {
        let ctx = &mut *(arg as *mut Ctx<F, R>);
        let func = ctx.func.take().expect("nogvl callback invoked twice");
        ctx.result = Some(catch_unwind(AssertUnwindSafe(func)));
        std::ptr::null_mut()
    }

    let mut ctx: Ctx<F, R> = Ctx {
        func: Some(f),
        result: None,
    };
    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(callback::<F, R>),
            &mut ctx as *mut Ctx<F, R> as *mut c_void,
            None,
            std::ptr::null_mut(),
        );
    }
    match ctx.result.expect("nogvl callback did not run") {
        Ok(result) => result,
        Err(panic) => resume_unwind(panic),
    }
}

/// Helper to create a binary Ruby string from bytes. Called only with the GVL
/// held (after the native work finishes), so `Ruby::get` always succeeds.
fn binary_string(bytes: &[u8]) -> RString {
    let ruby = Ruby::get().unwrap();
    let s = ruby.str_from_slice(bytes);
    let _ = s.enc_associate(ruby.ascii8bit_encindex());
    s
}

/// Copy a Ruby string's bytes so they can be used without the GVL.
fn copy_bytes(s: RString) -> Vec<u8> {
    unsafe { s.as_slice() }.to_vec()
}

/// Build a `YrbLite::Error` (the gem's own error class, defined in `init`) so
/// native decode/apply/validation failures surface as a project-specific error
/// rather than a generic RuntimeError. Falls back to RuntimeError only if the
/// class somehow can't be resolved.
fn yrb_error(msg: String) -> Error {
    let ruby = Ruby::get().unwrap();
    let class = ruby
        .eval::<ExceptionClass>("YrbLite::Error")
        .unwrap_or_else(|_| ruby.exception_runtime_error());
    Error::new(class, msg)
}

/// Yjs/lib0 client IDs must be JS-safe integers (<= 2^53 - 1). Above that they
/// round or collide when crossing the JS/Yjs boundary, and a client-id collision
/// corrupts a CRDT. Explicit (Ruby-supplied) IDs are validated here; the random
/// default IDs that yrs generates are already in range.
const MAX_SAFE_CLIENT_ID: u64 = (1 << 53) - 1;

/// Pure predicate (no Ruby), so the boundary is unit-testable without a VM.
fn is_safe_client_id(id: u64) -> bool {
    id <= MAX_SAFE_CLIENT_ID
}

fn validate_client_id(id: u64) -> Result<u64, Error> {
    if !is_safe_client_id(id) {
        return Err(yrb_error(format!(
            "client_id {id} exceeds the maximum safe integer ({MAX_SAFE_CLIENT_ID} = 2^53 - 1); \
             Yjs client IDs must be JS-safe integers to avoid collisions"
        )));
    }
    Ok(id)
}

// ============================================================================
// Pure protocol helpers (no Ruby, no GVL); unit-tested in the `tests` module.
// ============================================================================

/// Classify a frame: a non-zero code only for exactly one well-formed message
/// that consumes the whole buffer (see `RbAwareness::message_kind` for codes).
fn classify_message(bytes: &[u8]) -> u8 {
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
fn merged_doc_update(bytes: &[u8]) -> Result<Option<Vec<u8>>, String> {
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
fn awareness_client_ids_in(bytes: &[u8]) -> Result<Vec<u64>, String> {
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
fn update_is_ready(doc: &Doc, update_bytes: &[u8]) -> Result<bool, String> {
    let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;
    Ok(doc.transact().state_vector() >= update.state_vector_lower())
}

/// True if the doc holds pending structs or a pending delete set -- blocks that
/// couldn't integrate because a dependency is missing. Used as a backstop after
/// loading from storage: leftover pending means the stored log has a causal gap.
fn doc_has_pending(doc: &Doc) -> bool {
    let txn = doc.transact();
    txn.store().pending_update().is_some() || txn.store().pending_ds().is_some()
}

// ============================================================================
// Doc Implementation
// ============================================================================

impl RbDoc {
    /// Create a new Doc with an optional client_id
    fn new(args: &[Value]) -> Result<Self, Error> {
        let doc = if args.is_empty() {
            Doc::new()
        } else {
            let client_id = validate_client_id(TryConvert::try_convert(args[0])?)?;
            Doc::with_client_id(client_id)
        };
        Ok(RbDoc(doc))
    }

    /// Get the client ID
    fn client_id(&self) -> u64 {
        self.0.client_id().get()
    }

    /// Get the document GUID
    fn guid(&self) -> String {
        self.0.guid().to_string()
    }

    /// Get the current state vector encoded as bytes
    fn encode_state_vector(&self) -> RString {
        let doc = &self.0;
        let sv = nogvl(move || {
            let txn = doc.transact();
            txn.state_vector().encode_v1()
        });
        binary_string(&sv)
    }

    /// Encode state as update (optionally diffed against a state vector)
    fn encode_state_as_update(&self, args: &[Value]) -> Result<RString, Error> {
        let sv_bytes: Option<Vec<u8>> = if args.is_empty() {
            None
        } else {
            let sv_string: RString = TryConvert::try_convert(args[0])?;
            Some(copy_bytes(sv_string))
        };
        let doc = &self.0;
        let update = nogvl(move || -> Result<Vec<u8>, String> {
            let sv = match &sv_bytes {
                None => yrs::StateVector::default(),
                Some(bytes) => yrs::StateVector::decode_v1(bytes).map_err(|e| e.to_string())?,
            };
            let txn = doc.transact();
            Ok(txn.encode_state_as_update_v1(&sv))
        })
        .map_err(yrb_error)?;
        Ok(binary_string(&update))
    }

    /// Apply a V1 update to the document
    fn apply_update(&self, update: RString) -> Result<(), Error> {
        let update_bytes = copy_bytes(update);
        let doc = &self.0;
        nogvl(move || -> Result<(), String> {
            let update = yrs::Update::decode_v1(&update_bytes).map_err(|e| e.to_string())?;
            let mut txn = doc.transact_mut();
            txn.apply_update(update).map_err(|e| e.to_string())
        })
        .map_err(yrb_error)
    }

    /// True if applying `update` would integrate cleanly (its dependencies are
    /// all present). False means it would leave a pending struct -- an earlier
    /// update is missing. Pure read; does not mutate.
    fn update_ready(&self, update: RString) -> Result<bool, Error> {
        let update_bytes = copy_bytes(update);
        let doc = &self.0;
        nogvl(move || update_is_ready(doc, &update_bytes)).map_err(yrb_error)
    }

    /// True if the document holds pending (un-integrable) structs waiting on a
    /// missing dependency.
    fn pending(&self) -> bool {
        let doc = &self.0;
        nogvl(move || doc_has_pending(doc))
    }

    /// Sync step 1: Create a sync message with our state vector
    fn sync_step1(&self) -> RString {
        let doc = &self.0;
        let encoded = nogvl(move || {
            let txn = doc.transact();
            let sv = txn.state_vector();
            Message::Sync(SyncMessage::SyncStep1(sv)).encode_v1()
        });
        binary_string(&encoded)
    }

    /// Sync step 2: Create a sync message with updates for the given state vector
    fn sync_step2(&self, sv_bytes: RString) -> Result<RString, Error> {
        let sv_data = copy_bytes(sv_bytes);
        let doc = &self.0;
        let encoded = nogvl(move || -> Result<Vec<u8>, String> {
            let sv = yrs::StateVector::decode_v1(&sv_data).map_err(|e| e.to_string())?;
            let txn = doc.transact();
            let update = txn.encode_state_as_update_v1(&sv);
            Ok(Message::Sync(SyncMessage::SyncStep2(update)).encode_v1())
        })
        .map_err(yrb_error)?;
        Ok(binary_string(&encoded))
    }

    /// Handle a sync message and return response (if any)
    /// Returns [message_type, sync_type, response_bytes] or nil
    fn handle_sync_message(&self, data: RString) -> Result<Option<(u8, u8, RString)>, Error> {
        let data_bytes = copy_bytes(data);
        let doc = &self.0;

        let (msg_type, sync_type, response) =
            nogvl(move || -> Result<(u8, u8, Vec<u8>), String> {
                let msg = Message::decode_v1(&data_bytes).map_err(|e| e.to_string())?;

                match msg {
                    Message::Sync(sync_msg) => match sync_msg {
                        SyncMessage::SyncStep1(sv) => {
                            // Respond with SyncStep2
                            let txn = doc.transact();
                            let update = txn.encode_state_as_update_v1(&sv);
                            let response = Message::Sync(SyncMessage::SyncStep2(update));
                            Ok((0, 0, response.encode_v1()))
                        }
                        SyncMessage::SyncStep2(update_bytes) => {
                            // Apply the update
                            let update =
                                yrs::Update::decode_v1(&update_bytes).map_err(|e| e.to_string())?;
                            let mut txn = doc.transact_mut();
                            txn.apply_update(update).map_err(|e| e.to_string())?;
                            Ok((0, 1, Vec::new()))
                        }
                        SyncMessage::Update(update_bytes) => {
                            // Apply the update
                            let update =
                                yrs::Update::decode_v1(&update_bytes).map_err(|e| e.to_string())?;
                            let mut txn = doc.transact_mut();
                            txn.apply_update(update).map_err(|e| e.to_string())?;
                            Ok((0, 2, Vec::new()))
                        }
                    },
                    Message::Awareness(_) => Ok((1, 0, Vec::new())),
                    Message::AwarenessQuery => Ok((3, 0, Vec::new())),
                    Message::Auth(_) => Ok((2, 0, Vec::new())),
                    Message::Custom(tag, _) => Ok((tag, 0, Vec::new())),
                }
            })
            .map_err(yrb_error)?;

        Ok(Some((msg_type, sync_type, binary_string(&response))))
    }

    /// Encode raw update bytes as a sync Update message
    fn encode_update_message(&self, update: RString) -> RString {
        let update_bytes = copy_bytes(update);
        let msg = Message::Sync(SyncMessage::Update(update_bytes));
        binary_string(&msg.encode_v1())
    }
}

// ============================================================================
// Awareness Implementation (includes Doc + presence)
// ============================================================================

impl RbAwareness {
    /// Create a new Awareness with an optional client_id
    fn new(args: &[Value]) -> Result<Self, Error> {
        let awareness = if args.is_empty() {
            Awareness::new(Doc::new())
        } else {
            let client_id = validate_client_id(TryConvert::try_convert(args[0])?)?;
            Awareness::new(Doc::with_client_id(client_id))
        };
        Ok(RbAwareness(Mutex::new(awareness)))
    }

    /// Get the client ID of the underlying document
    fn client_id(&self) -> u64 {
        let awareness = &self.0;
        nogvl(move || awareness.lock().unwrap().doc().client_id().get())
    }

    /// Get the document GUID
    fn guid(&self) -> String {
        let awareness = &self.0;
        nogvl(move || awareness.lock().unwrap().doc().guid().to_string())
    }

    /// A standalone SyncStep1 message (the server's state vector). Sent as its
    /// own frame in the opening handshake so providers that parse one message
    /// per frame (e.g. @y-rb/actioncable) handle it correctly.
    fn sync_step1(&self) -> RString {
        let awareness = &self.0;
        let encoded = nogvl(move || {
            let doc = awareness.lock().unwrap().doc().clone();
            let txn = doc.transact();
            let sv = txn.state_vector();
            Message::Sync(SyncMessage::SyncStep1(sv)).encode_v1()
        });
        binary_string(&encoded)
    }

    /// Create initial sync messages to send when connection opens.
    /// Returns binary data containing SyncStep1 + Awareness update.
    fn start(&self) -> Result<RString, Error> {
        let awareness = &self.0;
        let encoded = nogvl(move || -> Result<Vec<u8>, String> {
            let awareness = awareness.lock().unwrap();
            let protocol = DefaultProtocol;
            let mut encoder = EncoderV1::new();
            protocol
                .start(&awareness, &mut encoder)
                .map_err(|e| e.to_string())?;
            Ok(encoder.to_vec())
        })
        .map_err(yrb_error)?;
        Ok(binary_string(&encoded))
    }

    /// Handle incoming message and return response messages (if any).
    /// Returns binary data containing response messages, or empty if no response needed.
    fn handle(&self, data: RString) -> Result<RString, Error> {
        let data_bytes = copy_bytes(data);
        let awareness = &self.0;

        let encoded = nogvl(move || -> Result<Vec<u8>, String> {
            let mut awareness = awareness.lock().unwrap();
            let protocol = DefaultProtocol;
            let responses = protocol
                .handle(&mut awareness, &data_bytes)
                .map_err(|e| e.to_string())?;

            if responses.is_empty() {
                return Ok(Vec::new());
            }

            let mut encoder = EncoderV1::new();
            for msg in responses {
                msg.encode(&mut encoder);
            }
            Ok(encoder.to_vec())
        })
        .map_err(yrb_error)?;
        Ok(binary_string(&encoded))
    }

    /// Encode an update message for broadcasting changes to peers.
    fn encode_update(&self, update: RString) -> RString {
        let update_bytes = copy_bytes(update);
        let msg = Message::Sync(SyncMessage::Update(update_bytes));
        binary_string(&msg.encode_v1())
    }

    /// Get the current state vector encoded as bytes
    fn encode_state_vector(&self) -> RString {
        let awareness = &self.0;
        let sv = nogvl(move || {
            let doc = awareness.lock().unwrap().doc().clone();
            let txn = doc.transact();
            txn.state_vector().encode_v1()
        });
        binary_string(&sv)
    }

    /// Encode state as update (optionally diffed against a state vector)
    fn encode_state_as_update(&self, args: &[Value]) -> Result<RString, Error> {
        let sv_bytes: Option<Vec<u8>> = if args.is_empty() {
            None
        } else {
            let sv_string: RString = TryConvert::try_convert(args[0])?;
            Some(copy_bytes(sv_string))
        };
        let awareness = &self.0;
        let update = nogvl(move || -> Result<Vec<u8>, String> {
            let sv = match &sv_bytes {
                None => yrs::StateVector::default(),
                Some(bytes) => yrs::StateVector::decode_v1(bytes).map_err(|e| e.to_string())?,
            };
            let doc = awareness.lock().unwrap().doc().clone();
            let txn = doc.transact();
            Ok(txn.encode_state_as_update_v1(&sv))
        })
        .map_err(yrb_error)?;
        Ok(binary_string(&update))
    }

    /// Set local awareness state (JSON string)
    fn set_local_state(&self, json: String) -> Result<(), Error> {
        let value: serde_json::Value =
            serde_json::from_str(&json).map_err(|e| yrb_error(e.to_string()))?;
        let awareness = &self.0;
        nogvl(move || -> Result<(), String> {
            awareness
                .lock()
                .unwrap()
                .set_local_state(value)
                .map_err(|e| e.to_string())
        })
        .map_err(yrb_error)
    }

    /// Get local awareness state as JSON string (or nil if not set)
    fn local_state(&self) -> Option<String> {
        let awareness = &self.0;
        nogvl(move || {
            awareness
                .lock()
                .unwrap()
                .local_state::<serde_json::Value>()
                .map(|v| v.to_string())
        })
    }

    /// Clear local awareness state
    fn clear_local_state(&self) {
        let awareness = &self.0;
        nogvl(move || awareness.lock().unwrap().clean_local_state());
    }

    /// Get awareness update for broadcasting to peers
    fn encode_awareness_update(&self) -> Result<RString, Error> {
        let awareness = &self.0;
        let encoded = nogvl(move || -> Result<Vec<u8>, String> {
            let awareness = awareness.lock().unwrap();
            let update = awareness.update().map_err(|e| e.to_string())?;
            Ok(Message::Awareness(update).encode_v1())
        })
        .map_err(yrb_error)?;
        Ok(binary_string(&encoded))
    }

    /// Apply a raw update to the underlying document
    fn apply_update(&self, update: RString) -> Result<(), Error> {
        let update_bytes = copy_bytes(update);
        let awareness = &self.0;
        nogvl(move || -> Result<(), String> {
            let update = yrs::Update::decode_v1(&update_bytes).map_err(|e| e.to_string())?;
            let doc = awareness.lock().unwrap().doc().clone();
            let mut txn = doc.transact_mut();
            txn.apply_update(update).map_err(|e| e.to_string())
        })
        .map_err(yrb_error)
    }

    /// True if applying `update` would integrate cleanly (its dependencies are
    /// all present). False means it depends on a missing, causally-prior update.
    /// Pure read; does not mutate.
    fn update_ready(&self, update: RString) -> Result<bool, Error> {
        let update_bytes = copy_bytes(update);
        let awareness = &self.0;
        nogvl(move || {
            let doc = awareness.lock().unwrap().doc().clone();
            update_is_ready(&doc, &update_bytes)
        })
        .map_err(yrb_error)
    }

    /// True if the document holds pending (un-integrable) structs waiting on a
    /// missing dependency.
    fn pending(&self) -> bool {
        let awareness = &self.0;
        nogvl(move || {
            let doc = awareness.lock().unwrap().doc().clone();
            doc_has_pending(&doc)
        })
    }

    /// Decode the awareness client IDs referenced by a protocol message
    /// (which may pack several sub-messages together). Sync sub-messages are
    /// ignored. The ActionCable layer uses this to learn which presence
    /// states arrived on a connection, so it can clear them when that
    /// connection closes.
    fn awareness_client_ids(&self, data: RString) -> Result<Vec<u64>, Error> {
        let data_bytes = copy_bytes(data);
        nogvl(move || awareness_client_ids_in(&data_bytes)).map_err(yrb_error)
    }

    /// Classify a frame for safe routing and relay. Returns a code only when
    /// the frame is exactly one well-formed message that consumes the whole
    /// buffer, so a malformed, truncated, multi-message, or trailing-garbage
    /// frame (which a malicious client could craft to disrupt others if
    /// relayed) is rejected up front:
    ///   0 = drop (malformed, multiple, unknown, or empty)
    ///   1 = sync step1       (a request: respond, do not relay)
    ///   2 = sync step2/update (a document change: record/apply/relay)
    ///   3 = awareness        (presence: relay)
    ///   4 = awareness query  (a request: respond, do not relay)
    fn message_kind(&self, data: RString) -> u8 {
        let data_bytes = copy_bytes(data);
        nogvl(move || classify_message(&data_bytes))
    }

    /// Extract the document-update delta carried by a protocol message: the
    /// payloads of any Update or SyncStep2 sub-messages, merged into a single
    /// update. Returns nil if the message carries no document change (for
    /// instance a SyncStep1 request or an awareness update). The strict audit
    /// path records this exact delta before applying it.
    fn update_from_message(&self, data: RString) -> Result<Option<RString>, Error> {
        let data_bytes = copy_bytes(data);
        let merged = nogvl(move || merged_doc_update(&data_bytes)).map_err(yrb_error)?;
        Ok(merged.map(|b| binary_string(&b)))
    }

    /// Mark the given clients as disconnected and return an awareness protocol
    /// message (null-state, bumped clock) announcing their removal to peers.
    /// Only clients currently known to this Awareness are removed; unknown
    /// IDs are skipped (so we never broadcast phantom removals). Returns an
    /// empty string when nothing was removed.
    fn remove_clients(&self, client_ids: Vec<u64>) -> Result<RString, Error> {
        let awareness = &self.0;
        let encoded = nogvl(move || -> Result<Vec<u8>, String> {
            let mut awareness = awareness.lock().unwrap();
            let mut removed = Vec::new();
            for id in client_ids {
                let cid = ClientID::new(id);
                if awareness.meta(cid).is_some() {
                    awareness.remove_state(cid);
                    removed.push(cid);
                }
            }
            if removed.is_empty() {
                return Ok(Vec::new());
            }
            let update = awareness
                .update_with_clients(removed)
                .map_err(|e| e.to_string())?;
            Ok(Message::Awareness(update).encode_v1())
        })
        .map_err(yrb_error)?;
        Ok(binary_string(&encoded))
    }
}

// ============================================================================
// Module Initialization
// ============================================================================

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("YrbLite")?;

    // Define error class
    let standard_error: magnus::RClass = ruby.eval("StandardError")?;
    let _error_class = module.define_class("Error", standard_error)?;

    // Define Doc class
    let doc_class = module.define_class("Doc", ruby.class_object())?;
    doc_class.define_singleton_method("new", function!(RbDoc::new, -1))?;
    doc_class.define_method("client_id", method!(RbDoc::client_id, 0))?;
    doc_class.define_method("guid", method!(RbDoc::guid, 0))?;
    doc_class.define_method(
        "encode_state_vector",
        method!(RbDoc::encode_state_vector, 0),
    )?;
    doc_class.define_method(
        "encode_state_as_update",
        method!(RbDoc::encode_state_as_update, -1),
    )?;
    doc_class.define_method("apply_update", method!(RbDoc::apply_update, 1))?;
    doc_class.define_method("update_ready?", method!(RbDoc::update_ready, 1))?;
    doc_class.define_method("pending?", method!(RbDoc::pending, 0))?;
    doc_class.define_method("sync_step1", method!(RbDoc::sync_step1, 0))?;
    doc_class.define_method("sync_step2", method!(RbDoc::sync_step2, 1))?;
    doc_class.define_method(
        "handle_sync_message",
        method!(RbDoc::handle_sync_message, 1),
    )?;
    doc_class.define_method(
        "encode_update_message",
        method!(RbDoc::encode_update_message, 1),
    )?;

    // Define Awareness class
    let awareness_class = module.define_class("Awareness", ruby.class_object())?;
    awareness_class.define_singleton_method("new", function!(RbAwareness::new, -1))?;
    awareness_class.define_method("client_id", method!(RbAwareness::client_id, 0))?;
    awareness_class.define_method("guid", method!(RbAwareness::guid, 0))?;
    awareness_class.define_method("start", method!(RbAwareness::start, 0))?;
    awareness_class.define_method("sync_step1", method!(RbAwareness::sync_step1, 0))?;
    awareness_class.define_method("handle", method!(RbAwareness::handle, 1))?;
    awareness_class.define_method("encode_update", method!(RbAwareness::encode_update, 1))?;
    awareness_class.define_method(
        "encode_state_vector",
        method!(RbAwareness::encode_state_vector, 0),
    )?;
    awareness_class.define_method(
        "encode_state_as_update",
        method!(RbAwareness::encode_state_as_update, -1),
    )?;
    awareness_class.define_method("apply_update", method!(RbAwareness::apply_update, 1))?;
    awareness_class.define_method("update_ready?", method!(RbAwareness::update_ready, 1))?;
    awareness_class.define_method("pending?", method!(RbAwareness::pending, 0))?;
    awareness_class.define_method("set_local_state", method!(RbAwareness::set_local_state, 1))?;
    awareness_class.define_method("local_state", method!(RbAwareness::local_state, 0))?;
    awareness_class.define_method(
        "clear_local_state",
        method!(RbAwareness::clear_local_state, 0),
    )?;
    awareness_class.define_method(
        "encode_awareness_update",
        method!(RbAwareness::encode_awareness_update, 0),
    )?;
    awareness_class.define_method(
        "awareness_client_ids",
        method!(RbAwareness::awareness_client_ids, 1),
    )?;
    awareness_class.define_method("remove_clients", method!(RbAwareness::remove_clients, 1))?;
    awareness_class.define_method(
        "update_from_message",
        method!(RbAwareness::update_from_message, 1),
    )?;
    awareness_class.define_method("message_kind", method!(RbAwareness::message_kind, 1))?;

    // Define message type constants
    module.const_set("MSG_SYNC", 0u8)?;
    module.const_set("MSG_AWARENESS", 1u8)?;
    module.const_set("MSG_AUTH", 2u8)?;
    module.const_set("MSG_QUERY_AWARENESS", 3u8)?;
    module.const_set("MSG_SYNC_STEP1", 0u8)?;
    module.const_set("MSG_SYNC_STEP2", 1u8)?;
    module.const_set("MSG_SYNC_UPDATE", 2u8)?;

    Ok(())
}

// ============================================================================
// Tests for the pure protocol helpers (run with `cargo test`, no Ruby VM)
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::sync::Awareness;
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
