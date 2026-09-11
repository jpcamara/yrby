//! Live `Y::XmlText` handles: write rich text from Ruby.
//!
//! Rich-text editors built on Yjs (Lexical among them) keep their document in
//! `XmlText` nodes: a root, blocks embedded in it, and inside a block a run of
//! embeds and strings. This handle exposes exactly the operations that shape
//! needs: read the text, set attributes, insert strings, insert embeds, and
//! append a nested `XmlText` block and get a handle to it.
//!
//! Same contract as the other handles: a transaction per operation inside
//! `nogvl`, no cached branch pointer, Ruby touched only with the GVL held.
//! Nested blocks are addressed by ordinal among their parent's embedded
//! `XmlText`s, so a handle re-resolves correctly after other edits.

use magnus::{prelude::*, r_hash::ForEach, Error, RHash, Ruby, Value};
use yrs::{
    Assoc, Doc, GetString, IndexScope, IndexedSequence, StickyIndex, Text, Transact, Xml,
    XmlTextPrelim,
};

use crate::shared::{
    embedded_xml_text_count, key_to_string, resolve_xml_text, ruby_to_invalue, to_in,
    to_map_prelim, InValue, Root, Seg,
};
use crate::{nogvl, yrb_error};

#[magnus::wrap(class = "Y::XmlText", free_immediately, size)]
pub struct RbXmlText {
    doc: Doc,
    root: String,
    path: Vec<Seg>,
}

/// A relative position, computed without the GVL and turned into a Ruby Hash
/// with it. Mirrors Yjs's RelativePosition JSON: inside a sequence it names
/// the item to the right (or left); at the end of a nested type it names the
/// type; at a root it names the root.
enum RelPos {
    Item(u64, u32),
    Type(u64, u32),
    Root(String),
}

fn clamp(index: i64, len: u32) -> u32 {
    let len = len as i64;
    let i = if index < 0 { len + index } else { index };
    i.clamp(0, len) as u32
}

/// Read a Ruby Hash into `Send` pairs with the GVL held.
fn hash_pairs(ruby: &Ruby, hash: RHash) -> Result<Vec<(String, InValue)>, Error> {
    let mut pairs = Vec::new();
    hash.foreach(|k: Value, v: Value| {
        pairs.push((key_to_string(k)?, ruby_to_invalue(ruby, v)?));
        Ok(ForEach::Continue)
    })?;
    Ok(pairs)
}

impl RbXmlText {
    pub fn root(doc: Doc, root: String) -> Self {
        RbXmlText {
            doc,
            root,
            path: Vec::new(),
        }
    }

    // --- reads ---

    fn to_s(&self) -> String {
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve_xml_text(&txn, Root::XmlText, root, path)
                .map(|x| x.get_string(&txn))
                .unwrap_or_default()
        })
    }

    fn length(&self) -> usize {
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve_xml_text(&txn, Root::XmlText, root, path)
                .map(|x| x.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn is_empty(&self) -> bool {
        self.length() == 0
    }

    /// How many `XmlText` blocks this one embeds.
    fn xml_text_count(&self) -> usize {
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve_xml_text(&txn, Root::XmlText, root, path)
                .map(|x| embedded_xml_text_count(&txn, &x) as usize)
                .unwrap_or(0)
        })
    }

    // --- writes ---

    /// Set one attribute (a string, number, or nil).
    fn set_attribute(&self, key: String, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let x = resolve_xml_text(&txn, Root::XmlText, root, path)
                .ok_or_else(|| "xml text no longer exists".to_string())?;
            x.insert_attribute(&mut txn, key, to_in(iv));
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(value)
    }

    /// Insert a string at `index` (clamped; negative counts from the end).
    fn insert(&self, index: i64, chunk: String) -> Result<String, Error> {
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        let text = chunk.clone();
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let x = resolve_xml_text(&txn, Root::XmlText, root, path)
                .ok_or_else(|| "xml text no longer exists".to_string())?;
            let at = clamp(index, x.len(&txn));
            x.insert(&mut txn, at, &text);
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(chunk)
    }

    /// Insert an embed at `index`. A Hash becomes a nested shared map, which
    /// is what an editor's node marker is (Lexical keeps a text node's
    /// properties in a `Y.Map` embedded before its characters). A scalar is
    /// embedded as a plain value.
    fn insert_embed(&self, index: i64, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let x = resolve_xml_text(&txn, Root::XmlText, root, path)
                .ok_or_else(|| "xml text no longer exists".to_string())?;
            let at = clamp(index, x.len(&txn));
            match iv {
                InValue::Map(entries) => {
                    x.insert_embed(&mut txn, at, to_map_prelim(entries));
                }
                InValue::Any(a) => {
                    x.insert_embed(&mut txn, at, a);
                }
            }
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(value)
    }

    /// The Yjs relative position of `index` as the `{type, tname, item, assoc}`
    /// hash editors put in awareness as a caret. `assoc` is "after" (the
    /// default: the space before the item at `index`) or "before".
    fn native_relative_position(&self, index: i64, assoc: String) -> Result<RHash, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let assoc = if assoc == "before" {
            Assoc::Before
        } else {
            Assoc::After
        };
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        let (pos, assoc) = nogvl(move || -> Result<(RelPos, i32), String> {
            let txn = doc.transact();
            let x = resolve_xml_text(&txn, Root::XmlText, root, path)
                .ok_or_else(|| "xml text no longer exists".to_string())?;
            let at = clamp(index, x.len(&txn));
            // Past the last item there is nothing to name, so Yjs anchors the
            // position to the type itself (the block, or the root). Same here.
            let sticky = x
                .sticky_index(&txn, at, assoc)
                .unwrap_or_else(|| StickyIndex::from_type(&txn, &x, assoc));
            let pos = match sticky.scope() {
                IndexScope::Relative(id) => RelPos::Item(id.client.get(), id.clock),
                IndexScope::Nested(id) => RelPos::Type(id.client.get(), id.clock),
                IndexScope::Root(name) => RelPos::Root(name.to_string()),
            };
            Ok((pos, sticky.assoc as i32))
        })
        .map_err(yrb_error)?;
        let id = |client: u64, clock: u32| -> Result<RHash, Error> {
            let h = ruby.hash_new();
            h.aset("client", client)?;
            h.aset("clock", clock)?;
            Ok(h)
        };
        let h = ruby.hash_new();
        h.aset("type", ruby.qnil())?;
        h.aset("tname", ruby.qnil())?;
        h.aset("item", ruby.qnil())?;
        match pos {
            RelPos::Item(c, k) => h.aset("item", id(c, k)?)?,
            RelPos::Type(c, k) => h.aset("type", id(c, k)?)?,
            RelPos::Root(name) => h.aset("tname", name)?,
        }
        h.aset("assoc", assoc)?;
        Ok(h)
    }

    /// Append a nested `XmlText` block with `attributes` and return a live
    /// handle to it. This is how a paragraph is added to a Lexical document.
    fn push_xml_text(&self, attributes: RHash) -> Result<RbXmlText, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let pairs = hash_pairs(&ruby, attributes)?;
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        let ordinal = nogvl(move || -> Result<u32, String> {
            let mut txn = doc.transact_mut();
            let x = resolve_xml_text(&txn, Root::XmlText, root, path)
                .ok_or_else(|| "xml text no longer exists".to_string())?;
            let ordinal = embedded_xml_text_count(&txn, &x);
            let at = x.len(&txn);
            let child = x.insert_embed(&mut txn, at, XmlTextPrelim::new(""));
            for (k, v) in pairs {
                child.insert_attribute(&mut txn, k, to_in(v));
            }
            Ok(ordinal)
        })
        .map_err(yrb_error)?;
        let mut child_path = self.path.clone();
        child_path.push(Seg::Embed(ordinal));
        Ok(RbXmlText {
            doc: self.doc.clone(),
            root: self.root.clone(),
            path: child_path,
        })
    }

    /// A live handle to the `n`-th embedded `XmlText` block.
    fn xml_text(&self, n: i64) -> Result<RbXmlText, Error> {
        if n < 0 {
            return Err(yrb_error("block index must be non-negative".to_string()));
        }
        let mut child_path = self.path.clone();
        child_path.push(Seg::Embed(n as u32));
        Ok(RbXmlText {
            doc: self.doc.clone(),
            root: self.root.clone(),
            path: child_path,
        })
    }
}

/// Ensure a root xml text exists and return a live handle. Called by
/// `Y::Doc#get_xml_text`.
pub fn root_xml_text(doc: &Doc, name: String) -> RbXmlText {
    let d = doc.clone();
    let root = name.clone();
    nogvl(move || {
        d.get_or_insert_xml_fragment(root.as_str());
    });
    RbXmlText::root(doc.clone(), name)
}

pub fn define(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    let class = module.define_class("XmlText", ruby.class_object())?;
    class.define_method("to_s", magnus::method!(RbXmlText::to_s, 0))?;
    class.define_method("to_str", magnus::method!(RbXmlText::to_s, 0))?;
    class.define_method("length", magnus::method!(RbXmlText::length, 0))?;
    class.define_method("size", magnus::method!(RbXmlText::length, 0))?;
    class.define_method("empty?", magnus::method!(RbXmlText::is_empty, 0))?;
    class.define_method(
        "xml_text_count",
        magnus::method!(RbXmlText::xml_text_count, 0),
    )?;
    class.define_method(
        "set_attribute",
        magnus::method!(RbXmlText::set_attribute, 2),
    )?;
    class.define_method("insert", magnus::method!(RbXmlText::insert, 2))?;
    class.define_method("insert_embed", magnus::method!(RbXmlText::insert_embed, 2))?;
    class.define_method(
        "push_xml_text",
        magnus::method!(RbXmlText::push_xml_text, 1),
    )?;
    class.define_method("xml_text", magnus::method!(RbXmlText::xml_text, 1))?;
    class.define_method(
        "native_relative_position",
        magnus::method!(RbXmlText::native_relative_position, 2),
    )?;
    Ok(())
}
