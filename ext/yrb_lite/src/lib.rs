mod prosemirror;

use magnus::{
    exception, function, method, prelude::*, Error, RString, Ruby, TryConvert, Value,
};
use yrs::sync::{Awareness, DefaultProtocol, Message, Protocol, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::{Encode, Encoder, EncoderV1};
use yrs::{Doc, ReadTxn, Transact};

/// Wrapper around yrs Doc.
///
/// Thread safety: `yrs::Doc` is `Send + Sync` — its `transact()`/`transact_mut()`
/// acquire an internal RwLock with *blocking* semantics, so concurrent access
/// from multiple Ruby threads serializes safely instead of panicking. No
/// interior-mutability wrapper (RefCell etc.) is needed or wanted here: every
/// method opens and closes its transaction within a single call.
#[magnus::wrap(class = "YrbLite::Doc", free_immediately, size)]
struct RbDoc(Doc);

/// Wrapper around yrs Awareness (which contains a Doc).
///
/// Thread safety: `yrs::sync::Awareness` keeps client states in a `DashMap`
/// and exposes all functionality through `&self` — it is designed for
/// multi-threaded server use.
#[magnus::wrap(class = "YrbLite::Awareness", free_immediately, size)]
struct RbAwareness(Awareness);

/// Compile-time proof that the wrapped types are thread-safe. If a future
/// yrs upgrade makes Doc or Awareness lose Send/Sync, this fails the build
/// instead of silently shipping a thread-unsafe gem.
#[allow(dead_code)]
fn assert_thread_safe() {
    fn is_send_sync<T: Send + Sync>() {}
    is_send_sync::<Doc>();
    is_send_sync::<Awareness>();
}

/// Run `f` with the GVL (Global VM Lock) released, allowing other Ruby
/// threads — including ones calling into this extension — to run in parallel.
///
/// SAFETY RULES for the closure:
/// - It must NOT touch any Ruby object or call any Ruby API. Inputs are
///   copied out of Ruby strings before entering, results are converted to
///   Ruby objects after returning.
/// - It must be `Send` (it runs while other threads own the GVL). `&Doc` and
///   `&Awareness` are fine: both types are `Sync` (asserted above).
/// - Any doc lock it takes is acquired AND released inside the closure, so we
///   never reacquire the GVL while holding a yrs lock (no lock-order deadlock).
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

/// Helper to create a binary Ruby string from bytes
fn binary_string(bytes: &[u8]) -> RString {
    let s = RString::from_slice(bytes);
    let _ = s.enc_associate(magnus::encoding::Index::ascii8bit());
    s
}

/// Copy a Ruby string's bytes so they can be used without the GVL.
fn copy_bytes(s: RString) -> Vec<u8> {
    unsafe { s.as_slice() }.to_vec()
}

fn runtime_error(msg: String) -> Error {
    Error::new(exception::runtime_error(), msg)
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
            let client_id: u64 = TryConvert::try_convert(args[0])?;
            Doc::with_client_id(client_id)
        };
        Ok(RbDoc(doc))
    }

    /// Get the client ID
    fn client_id(&self) -> u64 {
        self.0.client_id()
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
        .map_err(runtime_error)?;
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
        .map_err(runtime_error)
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
        .map_err(runtime_error)?;
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
                            let update = yrs::Update::decode_v1(&update_bytes)
                                .map_err(|e| e.to_string())?;
                            let mut txn = doc.transact_mut();
                            txn.apply_update(update).map_err(|e| e.to_string())?;
                            Ok((0, 1, Vec::new()))
                        }
                        SyncMessage::Update(update_bytes) => {
                            // Apply the update
                            let update = yrs::Update::decode_v1(&update_bytes)
                                .map_err(|e| e.to_string())?;
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
            .map_err(runtime_error)?;

        Ok(Some((msg_type, sync_type, binary_string(&response))))
    }

    /// Encode raw update bytes as a sync Update message
    fn encode_update_message(&self, update: RString) -> RString {
        let update_bytes = unsafe { update.as_slice() };
        let msg = Message::Sync(SyncMessage::Update(update_bytes.to_vec()));
        binary_string(&msg.encode_v1())
    }

    /// Extract ProseMirror content from this document as a JSON string.
    /// Optionally takes the name of the XML fragment to read (defaults to
    /// trying "prosemirror", "default", "doc").
    fn prosemirror_json(&self, args: &[Value]) -> Result<String, Error> {
        let fragment: Option<String> = if args.is_empty() {
            None
        } else {
            TryConvert::try_convert(args[0])?
        };
        let doc = &self.0;
        nogvl(move || -> Result<String, String> {
            let txn = doc.transact();
            let value = prosemirror::extract_from_txn(&txn, fragment.as_deref())?;
            Ok(value.to_string())
        })
        .map_err(runtime_error)
    }
}

/// Extract ProseMirror content from a raw V1 update as a JSON string.
/// Args: (update, fragment_name = nil)
fn extract_prosemirror_json(args: &[Value]) -> Result<String, Error> {
    if args.is_empty() || args.len() > 2 {
        return Err(Error::new(
            exception::arg_error(),
            format!("wrong number of arguments (given {}, expected 1..2)", args.len()),
        ));
    }
    let update: RString = TryConvert::try_convert(args[0])?;
    let fragment: Option<String> = if args.len() > 1 {
        TryConvert::try_convert(args[1])?
    } else {
        None
    };
    let bytes = copy_bytes(update);
    nogvl(move || -> Result<String, String> {
        let value = prosemirror::extract_from_update(&bytes, fragment.as_deref())?;
        Ok(value.to_string())
    })
    .map_err(runtime_error)
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
        Ok(RbAwareness(awareness))
    }

    /// Get the client ID of the underlying document
    fn client_id(&self) -> u64 {
        self.0.doc().client_id()
    }

    /// Get the document GUID
    fn guid(&self) -> String {
        self.0.doc().guid().to_string()
    }

    /// Create initial sync messages to send when connection opens.
    /// Returns binary data containing SyncStep1 + Awareness update.
    fn start(&self) -> Result<RString, Error> {
        let awareness = &self.0;
        let encoded = nogvl(move || -> Result<Vec<u8>, String> {
            let protocol = DefaultProtocol;
            let mut encoder = EncoderV1::new();
            protocol
                .start(awareness, &mut encoder)
                .map_err(|e| e.to_string())?;
            Ok(encoder.to_vec())
        })
        .map_err(runtime_error)?;
        Ok(binary_string(&encoded))
    }

    /// Handle incoming message and return response messages (if any).
    /// Returns binary data containing response messages, or empty if no response needed.
    fn handle(&self, data: RString) -> Result<RString, Error> {
        let data_bytes = copy_bytes(data);
        let awareness = &self.0;

        let encoded = nogvl(move || -> Result<Vec<u8>, String> {
            let protocol = DefaultProtocol;
            let responses = protocol
                .handle(awareness, &data_bytes)
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
        .map_err(runtime_error)?;
        Ok(binary_string(&encoded))
    }

    /// Encode an update message for broadcasting changes to peers.
    fn encode_update(&self, update: RString) -> RString {
        let update_bytes = unsafe { update.as_slice() };
        let msg = Message::Sync(SyncMessage::Update(update_bytes.to_vec()));
        binary_string(&msg.encode_v1())
    }

    /// Get the current state vector encoded as bytes
    fn encode_state_vector(&self) -> RString {
        let awareness = &self.0;
        let sv = nogvl(move || {
            let txn = awareness.doc().transact();
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
            let txn = awareness.doc().transact();
            Ok(txn.encode_state_as_update_v1(&sv))
        })
        .map_err(runtime_error)?;
        Ok(binary_string(&update))
    }

    /// Set local awareness state (JSON string)
    fn set_local_state(&self, json: String) -> Result<(), Error> {
        let awareness = &self.0;
        let value: serde_json::Value =
            serde_json::from_str(&json).map_err(|e| runtime_error(e.to_string()))?;
        awareness
            .set_local_state(value)
            .map_err(|e| runtime_error(e.to_string()))?;
        Ok(())
    }

    /// Get local awareness state as JSON string (or nil if not set)
    fn local_state(&self) -> Option<String> {
        let awareness = &self.0;
        awareness
            .local_state::<serde_json::Value>()
            .map(|v| v.to_string())
    }

    /// Clear local awareness state
    fn clear_local_state(&self) {
        let awareness = &self.0;
        awareness.clean_local_state();
    }

    /// Get awareness update for broadcasting to peers
    fn encode_awareness_update(&self) -> Result<RString, Error> {
        let awareness = &self.0;
        let update = awareness
            .update()
            .map_err(|e| runtime_error(e.to_string()))?;
        let msg = Message::Awareness(update);
        Ok(binary_string(&msg.encode_v1()))
    }

    /// Apply a raw update to the underlying document
    fn apply_update(&self, update: RString) -> Result<(), Error> {
        let update_bytes = copy_bytes(update);
        let awareness = &self.0;
        nogvl(move || -> Result<(), String> {
            let update = yrs::Update::decode_v1(&update_bytes).map_err(|e| e.to_string())?;
            let mut txn = awareness.doc().transact_mut();
            txn.apply_update(update).map_err(|e| e.to_string())
        })
        .map_err(runtime_error)
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
    doc_class.define_method("encode_state_vector", method!(RbDoc::encode_state_vector, 0))?;
    doc_class.define_method(
        "encode_state_as_update",
        method!(RbDoc::encode_state_as_update, -1),
    )?;
    doc_class.define_method("apply_update", method!(RbDoc::apply_update, 1))?;
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
    doc_class.define_method("prosemirror_json", method!(RbDoc::prosemirror_json, -1))?;

    // Module-level ProseMirror extraction from a raw update
    module.define_module_function(
        "extract_prosemirror_json",
        function!(extract_prosemirror_json, -1),
    )?;

    // Define Awareness class
    let awareness_class = module.define_class("Awareness", ruby.class_object())?;
    awareness_class.define_singleton_method("new", function!(RbAwareness::new, -1))?;
    awareness_class.define_method("client_id", method!(RbAwareness::client_id, 0))?;
    awareness_class.define_method("guid", method!(RbAwareness::guid, 0))?;
    awareness_class.define_method("start", method!(RbAwareness::start, 0))?;
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
