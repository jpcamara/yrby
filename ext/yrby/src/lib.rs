use magnus::{
    function, method, prelude::*, Error, ExceptionClass, IntoValue, RArray, RHash, RString, Ruby,
    TryConvert, Value,
};
use std::cell::RefCell;
use yrs::sync::{Awareness, Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{DeepObservable, Doc, GetString, ReadTxn, Text, Transact};

mod array;
mod map;
mod protocol;
mod read;
mod shared;
mod text;
mod xml_text;
use lexical_yjs_html as lexical_html;
use prosemirror_yjs_html as prosemirror_html;
use protocol::{
    classify_message, has_pending, integrated_update, merged_doc_update, update_advances_doc,
    update_is_ready,
};
use render_rules::{Rules, Segment};
pub(crate) use yjs_html_core as render_rules;

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
    is_send_sync::<map::RbMap>();
    is_send_sync::<array::RbArray>();
    is_send_sync::<text::RbText>();
    is_send_sync::<xml_text::RbXmlText>();
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
pub(crate) fn nogvl<F, R>(f: F) -> R
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
pub(crate) fn yrb_error(msg: String) -> Error {
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
            // first is still held deadlocks against a waiting writer, and
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

    /// A `Y.Array` root serialized to a JSON array string (values recursive, in
    /// array order). The counterpart to read_map for documents whose root is an
    /// array: a board's cards, a sheet's rows. Callers parse the JSON (e.g.
    /// `JSON.parse(doc.read_array("cards"))`). The serialization lives in
    /// `read::array_json` (pure, Rust-tested).
    fn read_array(&self, name: String) -> Option<String> {
        let doc = &self.0;
        nogvl(move || {
            let txn = doc.transact();
            let array = txn.get_array(name.as_str())?;
            Some(read::array_json(&txn, &array))
        })
    }

    /// True if the doc holds un-integrable pending structs or a pending delete
    /// set: content that couldn't integrate because a causally-prior update is
    /// missing. Such content is a recovery buffer, not document state; it heals if
    /// the missing dependency later arrives. A pure read.
    fn pending(&self) -> bool {
        let doc = &self.0;
        nogvl(move || has_pending(doc))
    }

    /// Like `encode_state_as_update` (full state), but **gap-free**: it excludes
    /// any pending (un-integrable) structs and pending delete set. Use this when
    /// persisting or serving state that other peers will apply. Serving pending
    /// content poisons their sync. Non-destructive: this doc keeps its pending, so
    /// a genuine gap still heals if its dependency arrives. (`encode_state_as_update`
    /// stays lossless for raw-update recovery.)
    fn compacted_state_update(&self) -> Result<RString, Error> {
        let doc = &self.0;
        let update = nogvl(move || integrated_update(doc, &yrs::StateVector::default()))
            .map_err(yrb_error)?;
        Ok(binary_string(&update))
    }

    /// A live `Y::Array` handle to the root array named `name` (created if
    /// absent). Writes through it mutate the document and sync to every peer.
    fn get_array(&self, name: String) -> array::RbArray {
        array::root_array(&self.0, name)
    }

    /// A live `Y::Text` handle to the root text named `name` (created if
    /// absent). This is what an agent appends into.
    fn get_text(&self, name: String) -> text::RbText {
        text::root_text(&self.0, name)
    }

    /// A live `Y::XmlText` handle to the root xml text named `name` (created
    /// if absent). Rich-text editors keep their document here; this is how a
    /// Ruby process writes a paragraph into one.
    fn get_xml_text(&self, name: String) -> xml_text::RbXmlText {
        xml_text::root_xml_text(&self.0, name)
    }

    /// A live `Y::Map` handle to the root map named `name` (created if absent).
    /// Unlike `read_map` (a JSON snapshot), the returned handle reads and *writes*
    /// the actual shared map, with the same thread-safety guarantees as the Doc.
    fn get_map(&self, name: String) -> map::RbMap {
        map::root_map(&self.0, name)
    }

    /// Apply `update` and report which top-level blocks of the root `XmlText`
    /// named `root` it touched, as ordinals: a change inside a block, a block
    /// added, or a block removed (the ordinal it had). This is what lets a
    /// process following a document react to the part that changed.
    fn apply_update_changes(&self, update: RString, root: String) -> Result<RArray, Error> {
        let bytes = copy_bytes(update);
        let doc = &self.0;
        let changed = nogvl(move || -> Result<Vec<u32>, String> {
            let fragment = doc.get_or_insert_xml_fragment(root.as_str());
            let branch: &yrs::branch::Branch = fragment.as_ref();
            let target = yrs::XmlTextRef::from(yrs::branch::BranchPtr::from(branch));
            let hits = std::sync::Arc::new(std::sync::Mutex::new(Vec::<u32>::new()));
            let sink = hits.clone();
            let subscription = target.observe_deep(move |txn, events| {
                let mut hits = sink.lock().unwrap();
                for event in events.iter() {
                    match event.path().front() {
                        Some(&yrs::types::PathSegment::Index(i)) => hits.push(i),
                        Some(_) => {}
                        None => root_positions(txn, event, &mut hits),
                    }
                }
            });
            let parsed = yrs::Update::decode_v1(&bytes).map_err(|e| e.to_string())?;
            {
                let mut txn = doc.transact_mut();
                txn.apply_update(parsed).map_err(|e| e.to_string())?;
            }
            drop(subscription);
            let mut out = hits.lock().unwrap().clone();
            out.sort_unstable();
            out.dedup();
            Ok(out)
        })
        .map_err(yrb_error)?;
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let array = ruby.ary_new();
        for i in changed {
            array.push(i)?;
        }
        Ok(array)
    }

    /// The ordinal of the top-level block of the root `XmlText` named `root`
    /// that a relative position (the `{type, tname, item, assoc}` hash a peer
    /// carries as a caret) falls in, or nil. This is how a process knows
    /// which block a person is writing in.
    fn block_at(&self, position: RHash, root: String) -> Result<Option<u32>, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let sticky = sticky_from_ruby(&ruby, position)?;
        let doc = &self.0;
        Ok(nogvl(move || {
            let txn = doc.transact();
            let target = sticky.get_offset(&txn)?.branch;
            let root_ref = shared::root_xml_text(&txn, root.as_str())?;
            let mut ordinal = 0u32;
            for d in root_ref.diff(&txn, yrs::types::text::YChange::identity) {
                if let yrs::Out::YXmlText(block) = &d.insert {
                    if contains_branch(&txn, block, target) {
                        return Some(ordinal);
                    }
                    ordinal += 1;
                }
            }
            None
        }))
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
                            // Respond with SyncStep2 carrying the doc's full
                            // state, pending included, matching Y.js's
                            // encodeStateAsUpdate. A peer parks a pending
                            // struct exactly as this doc does and heals it
                            // when the missing dependency arrives.
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
// Y::Lexical: schema-pinned rendering of Lexical/Lexxy documents
// ============================================================================

/// A Lexical view over a `Y::Doc`. The schema knowledge lives here rather
/// than on the schema-agnostic `Doc`: core Lexical natively, everything else
/// through the render rules compiled at construction (see `render_rules`;
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
    /// `Y::NativeLexical.new(doc, rules_json)`; the Y::Lexical facade
    /// compiles its `nodes:` config to the rules JSON.
    fn native_new(doc: &RbDoc, rules_json: String) -> Result<Self, Error> {
        Ok(RbLexical {
            doc: doc.0.clone(),
            rules: parse_rules(&rules_json)?,
        })
    }

    /// Render the document's XML root (default `"root"`, Lexical's standard
    /// collab root name) natively, with no Node process or headless editor. The
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

    /// The document's node types as observed facts, JSON-encoded, the
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
// Y::ProseMirror: schema-pinned rendering of ProseMirror/Tiptap documents
// ============================================================================

/// A ProseMirror view over a `Y::Doc`. The schema knowledge lives here rather
/// than on the schema-agnostic `Doc`: core ProseMirror natively, everything
/// else through the render rules compiled at construction (see
/// `render_rules`; the `Y::Tiptap` facade's rule set arrives that way).
/// Holds a cheap clone of the doc (yrs `Doc` is an Arc handle), so it reads
/// live state.
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
    /// `Y::NativeProseMirror.new(doc, rules_json)`; the Y::ProseMirror facade
    /// compiles its `nodes:`/`marks:` config to the rules JSON.
    fn native_new(doc: &RbDoc, rules_json: String) -> Result<Self, Error> {
        Ok(RbProseMirror {
            doc: doc.0.clone(),
            rules: parse_rules(&rules_json)?,
        })
    }

    /// Render an XML root (default `"default"`, the fragment name Tiptap's
    /// Collaboration extension uses). The native side renders core
    /// ProseMirror plus whatever the rules cover; with the rule set
    /// `Y::Tiptap` passes, output matches Tiptap's own `getHTML()`
    /// byte-for-byte on the reference fixtures (see `prosemirror_html.rs`
    /// for coverage and caveats). Returns nil when the root is missing or
    /// not ProseMirror-shaped (e.g. a Lexical document); a String when no
    /// callback rule fired; otherwise the nested segment arrays the Ruby
    /// layer splices.
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

    /// The document's node types as observed facts, JSON-encoded, the
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

/// A presence handle a Ruby process can use to appear as a live collaborator.
///
/// Wraps a yrs `Awareness`. `set_local_state` takes a JSON string (the shape the
/// editor renders, e.g. `{"name":"Agent","color":"#7c3aed"}`) and returns the
/// y-protocol awareness frame to broadcast. Browsers subscribed to the document
/// apply it as another participant. `clear_local_state` returns the frame that
/// removes this presence. The bytes are the same wire format Yjs and
/// y-protocols use, so no client change is needed.
#[magnus::wrap(class = "Y::Awareness", free_immediately, size)]
struct RbAwareness(RefCell<Awareness>);

impl RbAwareness {
    fn new(args: &[Value]) -> Result<Self, Error> {
        let doc = if args.is_empty() || args[0].is_nil() {
            Doc::new()
        } else {
            let client_id: u64 = TryConvert::try_convert(args[0])?;
            Doc::with_client_id(client_id)
        };
        Ok(RbAwareness(RefCell::new(Awareness::new(doc))))
    }

    /// This presence's client id, stable for the life of the handle.
    fn client_id(&self) -> u64 {
        self.0.borrow().client_id().get()
    }

    /// Set this client's presence from a JSON string and return the awareness
    /// frame to broadcast.
    fn set_local_state(&self, json: String) -> Result<RString, Error> {
        let value: serde_json::Value = serde_json::from_str(&json)
            .map_err(|e| yrb_error(format!("Y::Awareness state must be JSON: {e}")))?;
        let mut awareness = self.0.borrow_mut();
        awareness
            .set_local_state(value)
            .map_err(|e| yrb_error(e.to_string()))?;
        Self::frame(&awareness)
    }

    /// Remove this client's presence and return the frame that tells peers to
    /// drop it: an entry with the next clock and a null state, as y-protocols
    /// encodes a removal. yrs's own clean just forgets the client, and a
    /// frame built from that says nothing, so peers would wait for a timeout.
    fn clear_local_state(&self) -> Result<RString, Error> {
        let mut awareness = self.0.borrow_mut();
        let id = awareness.client_id();
        let clock = awareness
            .iter()
            .find(|(client, _)| *client == id)
            .map(|(_, state)| state.clock)
            .unwrap_or(0);
        awareness.clean_local_state();
        let mut clients = std::collections::HashMap::new();
        clients.insert(
            id,
            yrs::sync::awareness::AwarenessUpdateEntry {
                clock: clock + 1,
                json: "null".into(),
            },
        );
        let update = yrs::sync::awareness::AwarenessUpdate { clients };
        Ok(binary_string(&Message::Awareness(update).encode_v1()))
    }

    /// Apply a presence frame from another client (the bytes a browser or
    /// another process broadcast). Returns false for a frame that is not an
    /// awareness message.
    fn apply_update(&self, frame: RString) -> Result<bool, Error> {
        let bytes = copy_bytes(frame);
        let message = Message::decode_v1(&bytes).map_err(|e| yrb_error(e.to_string()))?;
        match message {
            Message::Awareness(update) => {
                self.0
                    .borrow_mut()
                    .apply_update(update)
                    .map_err(|e| yrb_error(e.to_string()))?;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    /// Every client's state, as `{ client_id => state }`, the state being the
    /// JSON each client set (parsed), or nil for a client that cleared it.
    fn states(&self) -> Result<RHash, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let entries: Vec<(u64, Option<String>)> = self
            .0
            .borrow()
            .iter()
            .map(|(id, state)| (id.get(), state.data.as_ref().map(|d| d.to_string())))
            .collect();
        let out = ruby.hash_new();
        for (id, data) in entries {
            let value: Value = match data {
                Some(json) => {
                    let parsed: serde_json::Value = serde_json::from_str(&json)
                        .map_err(|e| yrb_error(format!("presence state is not JSON: {e}")))?;
                    json_to_ruby(&ruby, &parsed)
                }
                None => ruby.qnil().as_value(),
            };
            out.aset(id, value)?;
        }
        Ok(out)
    }

    fn frame(awareness: &Awareness) -> Result<RString, Error> {
        let update = awareness.update().map_err(|e| yrb_error(e.to_string()))?;
        Ok(binary_string(&Message::Awareness(update).encode_v1()))
    }
}

/// For an event on the root sequence itself (a block added or removed), the
/// ordinals affected. The root's children are all embedded blocks, so a
/// sequence position is a block ordinal.
fn root_positions(txn: &yrs::TransactionMut, event: &yrs::types::Event, hits: &mut Vec<u32>) {
    use yrs::types::{Change, Delta, Event};
    let mut pos = 0u32;
    match event {
        Event::XmlFragment(e) => {
            for change in e.delta(txn) {
                match change {
                    Change::Retain(n) => pos += n,
                    Change::Added(items) => {
                        for k in 0..items.len() as u32 {
                            hits.push(pos + k);
                        }
                        pos += items.len() as u32;
                    }
                    Change::Removed(_) => hits.push(pos),
                }
            }
        }
        Event::XmlText(e) => {
            for delta in e.delta(txn) {
                match delta {
                    Delta::Retain(n, _) => pos += n,
                    Delta::Inserted(_, _) => {
                        hits.push(pos);
                        pos += 1;
                    }
                    Delta::Deleted(_) => hits.push(pos),
                }
            }
        }
        _ => {}
    }
}

/// Whether `branch` is `block` itself or embedded anywhere inside it.
fn contains_branch<T: ReadTxn>(
    txn: &T,
    block: &yrs::XmlTextRef,
    branch: yrs::branch::BranchPtr,
) -> bool {
    let this: &yrs::branch::Branch = block.as_ref();
    if yrs::branch::BranchPtr::from(this) == branch {
        return true;
    }
    for d in block.diff(txn, yrs::types::text::YChange::identity) {
        if let yrs::Out::YXmlText(child) = &d.insert {
            if contains_branch(txn, child, branch) {
                return true;
            }
        }
    }
    false
}

fn hash_get(ruby: &Ruby, h: RHash, key: &str) -> Option<Value> {
    h.get(ruby.to_symbol(key))
        .or_else(|| h.get(key))
        .filter(|v| !v.is_nil())
}

/// A yrs sticky index from the `{type, tname, item, assoc}` hash Yjs uses.
fn sticky_from_ruby(ruby: &Ruby, position: RHash) -> Result<yrs::StickyIndex, Error> {
    use yrs::{Assoc, IndexScope, StickyIndex};
    let assoc = match hash_get(ruby, position, "assoc") {
        Some(v) => {
            let n: i64 = TryConvert::try_convert(v)?;
            if n < 0 {
                Assoc::Before
            } else {
                Assoc::After
            }
        }
        None => Assoc::After,
    };
    let id_of = |key: &str| -> Result<Option<yrs::block::ID>, Error> {
        let Some(v) = hash_get(ruby, position, key) else {
            return Ok(None);
        };
        let h = RHash::from_value(v).ok_or_else(|| yrb_error(format!("{key} must be a hash")))?;
        let client: u64 = TryConvert::try_convert(
            hash_get(ruby, h, "client").ok_or_else(|| yrb_error("missing client".into()))?,
        )?;
        let clock: u32 = TryConvert::try_convert(
            hash_get(ruby, h, "clock").ok_or_else(|| yrb_error("missing clock".into()))?,
        )?;
        Ok(Some(yrs::block::ID::new(
            yrs::block::ClientID::new(client),
            clock,
        )))
    };
    if let Some(item) = id_of("item")? {
        return Ok(StickyIndex::from_id(item, assoc));
    }
    if let Some(ty) = id_of("type")? {
        return Ok(StickyIndex::new(IndexScope::Nested(ty), assoc));
    }
    match hash_get(ruby, position, "tname") {
        Some(v) => {
            let name: String = TryConvert::try_convert(v)?;
            Ok(StickyIndex::new(IndexScope::Root(name.into()), assoc))
        }
        None => Err(yrb_error("a position needs item, type, or tname".into())),
    }
}

/// serde_json to Ruby, for presence states.
fn json_to_ruby(ruby: &Ruby, v: &serde_json::Value) -> Value {
    match v {
        serde_json::Value::Null => ruby.qnil().as_value(),
        serde_json::Value::Bool(b) => b.into_value_with(ruby),
        serde_json::Value::Number(n) => match n.as_i64() {
            Some(i) => i.into_value_with(ruby),
            None => n.as_f64().unwrap_or(0.0).into_value_with(ruby),
        },
        serde_json::Value::String(s) => s.as_str().into_value_with(ruby),
        serde_json::Value::Array(a) => {
            let arr = ruby.ary_new();
            for x in a {
                let _ = arr.push(json_to_ruby(ruby, x));
            }
            arr.as_value()
        }
        serde_json::Value::Object(o) => {
            let h = ruby.hash_new();
            for (k, x) in o {
                let _ = h.aset(k.as_str(), json_to_ruby(ruby, x));
            }
            h.as_value()
        }
    }
}

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
    doc_class.define_method(
        "apply_update_changes",
        method!(RbDoc::apply_update_changes, 2),
    )?;
    doc_class.define_method("block_at", method!(RbDoc::block_at, 2))?;
    doc_class.define_method("root_names", method!(RbDoc::root_names, 0))?;
    doc_class.define_method("read_text", method!(RbDoc::read_text, 1))?;
    doc_class.define_method("read_xml", method!(RbDoc::read_xml, 1))?;
    doc_class.define_method("read_map", method!(RbDoc::read_map, 1))?;
    doc_class.define_method("read_array", method!(RbDoc::read_array, 1))?;
    doc_class.define_method("pending?", method!(RbDoc::pending, 0))?;
    doc_class.define_method(
        "compacted_state_update",
        method!(RbDoc::compacted_state_update, 0),
    )?;
    doc_class.define_method("get_map", method!(RbDoc::get_map, 1))?;
    doc_class.define_method("get_array", method!(RbDoc::get_array, 1))?;
    doc_class.define_method("get_text", method!(RbDoc::get_text, 1))?;
    doc_class.define_method("get_xml_text", method!(RbDoc::get_xml_text, 1))?;
    doc_class.define_method("update_ready?", method!(RbDoc::update_ready, 1))?;
    doc_class.define_method("update_advances?", method!(RbDoc::update_advances, 1))?;
    doc_class.define_method("sync_step1", method!(RbDoc::sync_step1, 0))?;
    doc_class.define_method(
        "handle_sync_message",
        method!(RbDoc::handle_sync_message, 1),
    )?;
    // The native renderers are the handles the Ruby facades (Y::Lexical /
    // Y::Lexxy and Y::ProseMirror / Y::Tiptap in lib/y/) hold; the Ruby
    // layer marks these classes private_constant.
    let lexical_class = module.define_class("NativeLexical", ruby.class_object())?;
    lexical_class.define_singleton_method("new", function!(RbLexical::native_new, 2))?;
    lexical_class.define_method("to_html", method!(RbLexical::native_to_html, -1))?;
    lexical_class.define_method("node_types", method!(RbLexical::node_types, -1))?;
    let prosemirror_class = module.define_class("NativeProseMirror", ruby.class_object())?;
    prosemirror_class.define_singleton_method("new", function!(RbProseMirror::native_new, 2))?;
    prosemirror_class.define_method("to_html", method!(RbProseMirror::native_to_html, -1))?;
    prosemirror_class.define_method("node_types", method!(RbProseMirror::node_types, -1))?;

    let awareness_class = module.define_class("Awareness", ruby.class_object())?;
    awareness_class.define_singleton_method("new", function!(RbAwareness::new, -1))?;
    awareness_class.define_method("client_id", method!(RbAwareness::client_id, 0))?;
    awareness_class.define_method("set_local_state", method!(RbAwareness::set_local_state, 1))?;
    awareness_class.define_method(
        "clear_local_state",
        method!(RbAwareness::clear_local_state, 0),
    )?;
    awareness_class.define_method("apply_update", method!(RbAwareness::apply_update, 1))?;
    awareness_class.define_method("states", method!(RbAwareness::states, 0))?;

    // Live shared-type handles.
    map::define(ruby, module)?;
    array::define(ruby, module)?;
    text::define(ruby, module)?;
    xml_text::define(ruby, module)?;

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
