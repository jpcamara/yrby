use magnus::{
    function, method, prelude::*, Error, ExceptionClass, IntoValue, RArray, RString, Ruby,
    TryConvert, Value,
};
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, GetString, ReadTxn, Transact};

mod lexical_html;
mod prosemirror_html;
mod protocol;
mod read;
mod render_rules;
use protocol::{
    classify_message, has_pending, integrated_update, merged_doc_update, update_advances_doc,
    update_is_ready,
};
use render_rules::{Rules, Segment};

/// Wrapper around yrs Doc.
///
/// Thread safety: `yrs::Doc` is `Send + Sync`. Its `transact()`/`transact_mut()`
/// acquire an internal RwLock with blocking semantics, so concurrent access from
/// multiple Ruby threads serializes safely instead of panicking. There's no
/// interior-mutability wrapper (RefCell and friends): every method opens and
/// closes its transaction within a single call.
#[magnus::wrap(class = "Y::Doc", free_immediately, size)]
struct RbDoc(Doc);

/// Compile-time proof that the wrapped Doc is thread-safe. If a future yrs
/// upgrade makes Doc lose Send/Sync, this fails the build instead of silently
/// shipping a thread-unsafe gem.
#[allow(dead_code)]
fn assert_thread_safe() {
    fn is_send_sync<T: Send + Sync>() {}
    is_send_sync::<Doc>();
    is_send_sync::<RbLexical>();
    is_send_sync::<RbProseMirror>();
}

/// Run `f` with the GVL (Global VM Lock) released, so other Ruby threads,
/// including ones calling into this extension, can run in parallel.
///
/// Safety rules for the closure:
/// - It must not touch any Ruby object or call any Ruby API. Inputs are copied
///   out of Ruby strings before entering, and results are converted to Ruby
///   objects after returning.
/// - It must be `Send` (it runs while other threads own the GVL). `&Doc` is
///   fine: it's `Sync` (asserted above).
/// - Lock discipline: any native lock it takes (the doc's internal RwLock) must
///   be acquired and released inside this closure, with the GVL already dropped.
///   Never lock with the GVL held (e.g. before calling `nogvl`), or a thread
///   waiting on the lock while holding the GVL can deadlock against the GVL
///   reacquire. Same reason we never hold a lock across the GVL boundary.
///
/// The closure runs with no unblock function, so it is not interruptible: a
/// Thread#kill, timeout, or signal can't preempt it mid-run. That's fine for the
/// bounded CRDT work it does; never call anything blocking or unbounded inside it.
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

/// Build a `Y::Error` (the gem's own error class, defined in `init`) so
/// native decode/apply failures surface as a project-specific error rather than
/// a generic RuntimeError. Falls back to RuntimeError only if the class somehow
/// can't be resolved.
fn yrb_error(msg: String) -> Error {
    let ruby = Ruby::get().unwrap();
    let class = ruby
        .eval::<ExceptionClass>("Y::Error")
        .unwrap_or_else(|_| ruby.exception_runtime_error());
    Error::new(class, msg)
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

    fn encode_state_vector(&self) -> RString {
        let doc = &self.0;
        let sv = nogvl(move || {
            let txn = doc.transact();
            txn.state_vector().encode_v1()
        });
        binary_string(&sv)
    }

    /// Names of the document's root types, so a content reader can find the one
    /// holding text without knowing it up front.
    fn root_names(&self) -> Vec<String> {
        let doc = &self.0;
        nogvl(move || {
            doc.transact()
                .root_refs()
                .map(|(name, _)| name.to_string())
                .collect()
        })
    }

    fn read_text(&self, name: String) -> Option<String> {
        let doc = &self.0;
        nogvl(move || {
            // Exactly ONE transaction per call. Opening a second while the
            // first is still held deadlocks against a waiting writer — and
            // inside nogvl that hang can't be interrupted.
            let txn = doc.transact();
            txn.get_text(name.as_str()).map(|t| t.get_string(&txn))
        })
    }

    /// Text of an XML-shaped root, one top-level block per line. The walk +
    /// block-join logic lives in `read::xml_blocks_text` (pure, Rust-tested);
    /// this just opens the transaction and resolves the root.
    fn read_xml(&self, name: String) -> Option<String> {
        let doc = &self.0;
        nogvl(move || {
            let txn = doc.transact();
            let fragment = txn.get_xml_fragment(name.as_str())?;
            Some(read::xml_blocks_text(&txn, &fragment))
        })
    }

    /// A `Y.Map` root serialized to a JSON object string (keys sorted; values
    /// recursive). Complements read_text/read_xml for structured shared state.
    /// Callers parse the JSON (e.g. `JSON.parse(doc.read_map("state"))`). The
    /// serialization lives in `read::map_json` (pure, Rust-tested).
    fn read_map(&self, name: String) -> Option<String> {
        let doc = &self.0;
        nogvl(move || {
            let txn = doc.transact();
            let map = txn.get_map(name.as_str())?;
            Some(read::map_json(&txn, &map))
        })
    }

    /// True if the doc holds un-integrable pending structs or a pending delete
    /// set — content that couldn't integrate because a causally-prior update is
    /// missing. Such content is a recovery buffer, not document state; it heals if
    /// the missing dependency later arrives. A pure read.
    fn pending(&self) -> bool {
        let doc = &self.0;
        nogvl(move || has_pending(doc))
    }

    /// Like `encode_state_as_update` (full state), but **gap-free**: it excludes
    /// any pending (un-integrable) structs and pending delete set. Use this when
    /// persisting or serving state that other peers will apply — serving pending
    /// content poisons their sync. Non-destructive: this doc keeps its pending, so
    /// a genuine gap still heals if its dependency arrives. (`encode_state_as_update`
    /// stays lossless for raw-update recovery.)
    fn compacted_state_update(&self) -> Result<RString, Error> {
        let doc = &self.0;
        let update = nogvl(move || integrated_update(doc, &yrs::StateVector::default()))
            .map_err(yrb_error)?;
        Ok(binary_string(&update))
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
    /// all present). False means it would leave a pending struct, i.e. an earlier
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

    /// Handle a Sync or Awareness message, returning
    /// [message_type, sync_type, response_bytes]. Only Sync (step1/step2/update)
    /// and Awareness are handled; any other frame type is rejected.
    fn handle_sync_message(&self, data: RString) -> Result<(u8, u8, RString), Error> {
        let data_bytes = copy_bytes(data);
        let doc = &self.0;

        let (msg_type, sync_type, response) =
            nogvl(move || -> Result<(u8, u8, Vec<u8>), String> {
                let msg = Message::decode_v1(&data_bytes).map_err(|e| e.to_string())?;

                match msg {
                    Message::Sync(sync_msg) => match sync_msg {
                        SyncMessage::SyncStep1(sv) => {
                            // Respond with SyncStep2 carrying only *integrated*
                            // state. Never hand a peer un-integrable pending
                            // structs: the peer would park the same pending
                            // forever and the state-vector/content mismatch drives
                            // endless resync traffic. (integrated_update is a no-op
                            // fast path when nothing is pending.)
                            let update = integrated_update(doc, &sv)?;
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
                    // Auth, awareness-query, and custom frames aren't part of this
                    // protocol; reject rather than pretend to handle them.
                    _ => Err("unsupported message type".to_string()),
                }
            })
            .map_err(yrb_error)?;

        Ok((msg_type, sync_type, binary_string(&response)))
    }
}

// ============================================================================
// Y::Lexical — schema-pinned rendering of Lexical/Lexxy documents
// ============================================================================

/// A Lexical view over a `Y::Doc`. The schema knowledge lives here rather
/// than on the schema-agnostic `Doc`: core Lexical natively, everything else
/// through the render rules compiled at construction (see `render_rules` —
/// the `Y::Lexxy` facade's rule set arrives that way). Holds a cheap clone of
/// the doc (yrs `Doc` is an Arc handle), so it reads live state.
///
/// Thread safety matches `Y::Doc`: every method opens its own transaction
/// inside `nogvl` and holds no lock across the GVL boundary. Callback rules
/// keep that discipline: the render emits deferred segments, and the Ruby
/// layer runs the app's blocks only after the transaction has closed.
#[magnus::wrap(class = "Y::NativeLexical", free_immediately, size)]
struct RbLexical {
    doc: Doc,
    rules: Rules,
}

impl RbLexical {
    /// `Y::NativeLexical.new(doc, rules_json)` — the Y::Lexical facade
    /// compiles its `nodes:` config to the rules JSON.
    fn native_new(doc: &RbDoc, rules_json: String) -> Result<Self, Error> {
        Ok(RbLexical {
            doc: doc.0.clone(),
            rules: parse_rules(&rules_json)?,
        })
    }

    /// Render the document's XML root (default `"root"`, Lexical's standard
    /// collab root name) natively — no Node process or headless editor. The
    /// native side renders core Lexical plus whatever the rules cover; with
    /// the rule set `Y::Lexxy` passes, output matches Lexxy's own serializer
    /// byte-for-byte on the reference fixtures (see `lexical_html.rs`). Returns nil when the root is missing or not
    /// Lexical-shaped, e.g. a ProseMirror document; a String when no
    /// callback rule fired; otherwise the nested segment arrays the Ruby
    /// layer splices.
    fn native_to_html(&self, args: &[Value]) -> Result<Value, Error> {
        let name = root_name_arg(args, "root")?;
        let doc = &self.doc;
        let rules = &self.rules;
        let segments = nogvl(move || {
            let txn = doc.transact();
            let fragment = txn.get_xml_fragment(name.as_str())?;
            lexical_html::render_segments(&txn, &fragment, rules)
        });
        segments_result(segments)
    }

    /// The document's node types as observed facts, JSON-encoded — the
    /// native half of the facade's `node_types` discovery aid. Nil when the
    /// root is missing or not Lexical-shaped.
    fn node_types(&self, args: &[Value]) -> Result<Value, Error> {
        let name = root_name_arg(args, "root")?;
        let doc = &self.doc;
        let map = nogvl(move || {
            let txn = doc.transact();
            let fragment = txn.get_xml_fragment(name.as_str())?;
            lexical_html::collect_node_types(&txn, &fragment)
        });
        let ruby = Ruby::get().unwrap();
        match map {
            None => Ok(ruby.qnil().as_value()),
            Some(map) => Ok(render_rules::type_map_json(&map, |ty| {
                if self.rules.nodes.contains_key(ty) {
                    Some("rule")
                } else if lexical_html::is_builtin(ty) {
                    Some("builtin")
                } else {
                    None
                }
            })
            .into_value_with(&ruby)),
        }
    }
}

// ============================================================================
// Y::ProseMirror — schema-pinned rendering of ProseMirror/Tiptap documents
// ============================================================================

/// A ProseMirror/Tiptap view over a `Y::Doc`. The schema knowledge (node/mark
/// names, Tiptap's serializer semantics) lives here rather than on the
/// schema-agnostic `Doc`. Holds a cheap clone of the doc (yrs `Doc` is an Arc
/// handle), so it reads live state, plus the custom render rules compiled at
/// construction (see `render_rules`).
///
/// Thread safety matches `Y::Doc`: every method opens its own transaction
/// inside `nogvl` and holds no lock across the GVL boundary. Callback rules
/// keep that discipline: the render emits deferred segments, and the Ruby
/// layer runs the app's blocks only after the transaction has closed.
#[magnus::wrap(class = "Y::NativeProseMirror", free_immediately, size)]
struct RbProseMirror {
    doc: Doc,
    rules: Rules,
}

impl RbProseMirror {
    /// `Y::NativeProseMirror.new(doc, rules_json)` — the Y::ProseMirror facade
    /// compiles its `nodes:`/`marks:` config to the rules JSON.
    fn native_new(doc: &RbDoc, rules_json: String) -> Result<Self, Error> {
        Ok(RbProseMirror {
            doc: doc.0.clone(),
            rules: parse_rules(&rules_json)?,
        })
    }

    /// Render an XML root (default `"default"`, the fragment name Tiptap's
    /// Collaboration extension uses). Output follows tiptap-php and matches
    /// Tiptap's `getHTML()` on the reference fixture; see
    /// `prosemirror_html.rs` for coverage and caveats. Returns nil when the
    /// root is missing or not ProseMirror-shaped (e.g. a Lexical document); a
    /// String when no callback rule fired; otherwise the nested segment arrays
    /// the Ruby layer splices.
    fn native_to_html(&self, args: &[Value]) -> Result<Value, Error> {
        let name = root_name_arg(args, "default")?;
        let doc = &self.doc;
        let rules = &self.rules;
        let segments = nogvl(move || {
            let txn = doc.transact();
            let fragment = txn.get_xml_fragment(name.as_str())?;
            prosemirror_html::render_segments(&txn, &fragment, rules)
        });
        segments_result(segments)
    }

    /// The document's node types as observed facts, JSON-encoded — the
    /// native half of the facade's `node_types` discovery aid. Nil when the
    /// root is missing or not ProseMirror-shaped.
    fn node_types(&self, args: &[Value]) -> Result<Value, Error> {
        let name = root_name_arg(args, "default")?;
        let doc = &self.doc;
        let map = nogvl(move || {
            let txn = doc.transact();
            let fragment = txn.get_xml_fragment(name.as_str())?;
            prosemirror_html::collect_node_types(&txn, &fragment)
        });
        let ruby = Ruby::get().unwrap();
        match map {
            None => Ok(ruby.qnil().as_value()),
            Some(map) => Ok(render_rules::type_map_json(&map, |ty| {
                if self.rules.nodes.contains_key(ty) {
                    Some("rule")
                } else if prosemirror_html::is_builtin(ty) {
                    Some("builtin")
                } else {
                    None
                }
            })
            .into_value_with(&ruby)),
        }
    }
}

/// The optional positional root-fragment name both renderers take.
fn root_name_arg(args: &[Value], default: &str) -> Result<String, Error> {
    if args.len() > 1 {
        let ruby = Ruby::get().unwrap();
        return Err(Error::new(
            ruby.exception_arg_error(),
            format!(
                "wrong number of arguments (given {}, expected 0..1)",
                args.len()
            ),
        ));
    }
    match args.first() {
        Some(arg) => TryConvert::try_convert(*arg),
        None => Ok(default.to_string()),
    }
}

fn parse_rules(json: &str) -> Result<Rules, Error> {
    Rules::parse(json).map_err(|e| {
        let ruby = Ruby::get().unwrap();
        Error::new(ruby.exception_arg_error(), e)
    })
}

/// A render's result as a Ruby value: nil (root missing or foreign-shaped),
/// a String when every segment is finished HTML, or nested arrays of
/// `String | [node_type, attrs_json, content, child_types]` for the Ruby
/// layer to splice.
fn segments_result(segments: Option<Vec<Segment>>) -> Result<Value, Error> {
    let ruby = Ruby::get().unwrap();
    match segments {
        None => Ok(ruby.qnil().as_value()),
        Some(segs) => match render_rules::flatten(segs) {
            render_rules::Flattened::Html(html) => Ok(html.into_value_with(&ruby)),
            render_rules::Flattened::Deferred(segs) => {
                Ok(segments_to_ruby(&ruby, segs)?.as_value())
            }
        },
    }
}

fn segments_to_ruby(ruby: &Ruby, segments: Vec<Segment>) -> Result<RArray, Error> {
    let arr = ruby.ary_new();
    for seg in segments {
        match seg {
            Segment::Html(s) => arr.push(s)?,
            Segment::Deferred {
                node_type,
                attrs_json,
                child_types,
                content,
            } => {
                let entry = ruby.ary_new();
                entry.push(node_type)?;
                entry.push(attrs_json)?;
                entry.push(segments_to_ruby(ruby, content)?)?;
                entry.push(child_types)?;
                arr.push(entry)?;
            }
        }
    }
    Ok(arr)
}

// ============================================================================
// Protocol codec (stateless), exposed as `Y` module functions
// ============================================================================
//
// The server never holds presence or document state to classify a frame; these
// are pure functions of their bytes. (Presence lives in the browser clients; the
// server only relays awareness frames opaquely.)

/// Wrap a raw document update in a sync Update message frame, ready to relay.
fn wrap_update(update: RString) -> RString {
    let update_bytes = copy_bytes(update);
    let msg = Message::Sync(SyncMessage::Update(update_bytes));
    binary_string(&msg.encode_v1())
}

/// Classify a frame for safe routing and relay. Returns a code only when the
/// frame is exactly one well-formed message that consumes the whole buffer, so
/// a malformed, truncated, multi-message, or trailing-garbage frame (which a
/// malicious client could craft to disrupt others if relayed) is rejected up
/// front:
///   0 = drop (malformed, multiple, unknown, or empty)
///   1 = sync step1       (a request: respond, do not relay)
///   2 = sync step2/update (a document change: record/apply/relay)
///   3 = awareness        (presence: relay)
///   4 = awareness query  (a request: respond, do not relay)
fn message_kind(data: RString) -> u8 {
    let data_bytes = copy_bytes(data);
    nogvl(move || classify_message(&data_bytes))
}

/// Extract the document-update delta carried by a protocol message: the payloads
/// of any Update or SyncStep2 sub-messages, merged into a single update. Returns
/// nil if the message carries no document change (a SyncStep1 request or an
/// awareness update). The store-backed path records this exact delta before relay.
fn update_from_message(data: RString) -> Result<Option<RString>, Error> {
    let data_bytes = copy_bytes(data);
    let merged = nogvl(move || merged_doc_update(&data_bytes)).map_err(yrb_error)?;
    Ok(merged.map(|b| binary_string(&b)))
}

// ============================================================================
// Module Initialization
// ============================================================================

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Y")?;

    // Define error class
    let standard_error: magnus::RClass = ruby.eval("StandardError")?;
    let _error_class = module.define_class("Error", standard_error)?;

    // Define Doc class
    let doc_class = module.define_class("Doc", ruby.class_object())?;
    doc_class.define_singleton_method("new", function!(RbDoc::new, -1))?;
    doc_class.define_method(
        "encode_state_vector",
        method!(RbDoc::encode_state_vector, 0),
    )?;
    doc_class.define_method(
        "encode_state_as_update",
        method!(RbDoc::encode_state_as_update, -1),
    )?;
    doc_class.define_method("apply_update", method!(RbDoc::apply_update, 1))?;
    doc_class.define_method("root_names", method!(RbDoc::root_names, 0))?;
    doc_class.define_method("read_text", method!(RbDoc::read_text, 1))?;
    doc_class.define_method("read_xml", method!(RbDoc::read_xml, 1))?;
    doc_class.define_method("read_map", method!(RbDoc::read_map, 1))?;
    doc_class.define_method("pending?", method!(RbDoc::pending, 0))?;
    doc_class.define_method(
        "compacted_state_update",
        method!(RbDoc::compacted_state_update, 0),
    )?;
    doc_class.define_method("update_ready?", method!(RbDoc::update_ready, 1))?;
    doc_class.define_method("update_advances?", method!(RbDoc::update_advances, 1))?;
    doc_class.define_method("sync_step1", method!(RbDoc::sync_step1, 0))?;
    doc_class.define_method(
        "handle_sync_message",
        method!(RbDoc::handle_sync_message, 1),
    )?;
    // The native renderers are the handles the Ruby facades (Y::Lexical /
    // Y::Lexxy and Y::ProseMirror in lib/y/) hold; the Ruby layer marks
    // these classes private_constant.
    let lexical_class = module.define_class("NativeLexical", ruby.class_object())?;
    lexical_class.define_singleton_method("new", function!(RbLexical::native_new, 2))?;
    lexical_class.define_method("to_html", method!(RbLexical::native_to_html, -1))?;
    lexical_class.define_method("node_types", method!(RbLexical::node_types, -1))?;
    let prosemirror_class = module.define_class("NativeProseMirror", ruby.class_object())?;
    prosemirror_class.define_singleton_method("new", function!(RbProseMirror::native_new, 2))?;
    prosemirror_class.define_method("to_html", method!(RbProseMirror::native_to_html, -1))?;
    prosemirror_class.define_method("node_types", method!(RbProseMirror::node_types, -1))?;

    // Stateless protocol codec, as Y module functions.
    module.define_module_function("wrap_update", function!(wrap_update, 1))?;
    module.define_module_function("message_kind", function!(message_kind, 1))?;
    module.define_module_function("update_from_message", function!(update_from_message, 1))?;

    // Define message type constants
    module.const_set("MSG_SYNC", 0u8)?;
    module.const_set("MSG_AWARENESS", 1u8)?;
    module.const_set("MSG_SYNC_STEP1", 0u8)?;
    module.const_set("MSG_SYNC_STEP2", 1u8)?;
    module.const_set("MSG_SYNC_UPDATE", 2u8)?;

    Ok(())
}
