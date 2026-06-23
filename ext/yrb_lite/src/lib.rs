use magnus::{
    function, method, prelude::*, Error, ExceptionClass, RString, Ruby, TryConvert, Value,
};
use std::sync::Mutex;
use yrs::sync::{Awareness, DefaultProtocol, Message, Protocol, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::{Encode, Encoder, EncoderV1};
use yrs::{Doc, ReadTxn, Transact};

mod protocol;
use protocol::{
    classify_message, doc_has_pending, merged_doc_update, update_advances_doc, update_is_ready,
};

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
/// native decode/apply failures surface as a project-specific error rather than
/// a generic RuntimeError. Falls back to RuntimeError only if the class somehow
/// can't be resolved.
fn yrb_error(msg: String) -> Error {
    let ruby = Ruby::get().unwrap();
    let class = ruby
        .eval::<ExceptionClass>("YrbLite::Error")
        .unwrap_or_else(|_| ruby.exception_runtime_error());
    Error::new(class, msg)
}

// CLIENT IDs ARE NOT VALIDATED -- whoever supplies the id (the app via
// `Doc.new(id)` / `Awareness.new(id)`, or a remote peer over the wire) is
// responsible for keeping it JS-safe (<= 2^53 - 1). See the protocol.rs header
// for why (and `ClientID::try_new`, proposed upstream, for strict rejection).

// ============================================================================
// Doc Implementation
// ============================================================================

impl RbDoc {
    /// Create a new Doc with an optional client_id
    fn new(args: &[Value]) -> Result<Self, Error> {
        let doc = if args.is_empty() {
            Doc::new()
        } else {
            let client_id: u64 = TryConvert::try_convert(args[0])?;
            Doc::with_client_id(client_id)
        };
        Ok(RbDoc(doc))
    }

    fn client_id(&self) -> u64 {
        self.0.client_id().get()
    }

    fn guid(&self) -> String {
        self.0.guid().to_string()
    }

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

    /// True if applying `update` would change the document (it carries new
    /// content), false if the doc already contains it (an already-applied
    /// retry). See `update_advances_doc`. Pure read; does not mutate.
    fn update_advances(&self, update: RString) -> Result<bool, Error> {
        let update_bytes = copy_bytes(update);
        let doc = &self.0;
        nogvl(move || update_advances_doc(doc, &update_bytes)).map_err(yrb_error)
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
            let client_id: u64 = TryConvert::try_convert(args[0])?;
            Awareness::new(Doc::with_client_id(client_id))
        };
        Ok(RbAwareness(Mutex::new(awareness)))
    }

    fn client_id(&self) -> u64 {
        let awareness = &self.0;
        nogvl(move || awareness.lock().unwrap().doc().client_id().get())
    }

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

    /// True if applying `update` would change the document, false if it's an
    /// already-applied retry. See `update_advances_doc`. Pure read.
    fn update_advances(&self, update: RString) -> Result<bool, Error> {
        let update_bytes = copy_bytes(update);
        let awareness = &self.0;
        nogvl(move || {
            let doc = awareness.lock().unwrap().doc().clone();
            update_advances_doc(&doc, &update_bytes)
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
    /// instance a SyncStep1 request or an awareness update). The store-backed
    /// path records this exact delta before relaying it.
    fn update_from_message(&self, data: RString) -> Result<Option<RString>, Error> {
        let data_bytes = copy_bytes(data);
        let merged = nogvl(move || merged_doc_update(&data_bytes)).map_err(yrb_error)?;
        Ok(merged.map(|b| binary_string(&b)))
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
    doc_class.define_method("update_advances?", method!(RbDoc::update_advances, 1))?;
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
    awareness_class.define_method("update_advances?", method!(RbAwareness::update_advances, 1))?;
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
