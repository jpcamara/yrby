//! Live `Y::Text` handles over a yrs `Text`: append and edit shared text from
//! Ruby.
//!
//! Same contract as the other handles: a transaction per operation inside
//! `nogvl`, no cached branch pointer, Ruby touched only with the GVL held.
//!
//! This is the type an agent streams into. `push` is the hot path, and it is a
//! CRDT insert at the current end rather than a whole-document write, so a
//! person typing in the same paragraph while the agent appends does not lose
//! their edit and neither does the agent.

use magnus::{prelude::*, Error, RHash, Ruby};
use yrs::{Assoc, Doc, GetString, IndexScope, IndexedSequence, StickyIndex, Text, Transact};

use crate::shared::{resolve_text, Root, Seg};
use crate::{nogvl, yrb_error};

enum RelPos {
    Item(u64, u32),
    Type(u64, u32),
    Root(String),
}

#[magnus::wrap(class = "Y::Text", free_immediately, size)]
pub struct RbText {
    doc: Doc,
    kind: Root,
    root: String,
    path: Vec<Seg>,
}

/// Ruby index semantics over a UTF-16-ish yrs index space. yrs counts in its own
/// units; we clamp rather than raise so a stale index from a concurrent edit is
/// a harmless no-op instead of an exception in an agent loop.
fn clamp(index: i64, len: u32) -> u32 {
    let len = len as i64;
    let i = if index < 0 { len + index } else { index };
    i.clamp(0, len) as u32
}

impl RbText {
    pub fn root(doc: Doc, root: String) -> Self {
        RbText {
            doc,
            kind: Root::Text,
            root,
            path: Vec::new(),
        }
    }

    pub fn at(doc: Doc, kind: Root, root: String, path: Vec<Seg>) -> Self {
        RbText {
            doc,
            kind,
            root,
            path,
        }
    }

    // --- reads ---

    fn to_s(&self) -> String {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve_text(&txn, kind, root, path)
                .map(|t| t.get_string(&txn))
                .unwrap_or_default()
        })
    }

    fn length(&self) -> usize {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve_text(&txn, kind, root, path)
                .map(|t| t.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn is_empty(&self) -> bool {
        self.length() == 0
    }

    // --- writes ---

    /// Append to the end. The operation an agent streaming output performs over
    /// and over, so it stays a single insert at the current length.
    fn push(&self, chunk: String) -> Result<String, Error> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let text = chunk.clone();
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let t = resolve_text(&txn, kind, root, path)
                .ok_or_else(|| "text no longer exists".to_string())?;
            let at = t.len(&txn);
            t.insert(&mut txn, at, &text);
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(chunk)
    }

    /// Insert at `index`, clamped into range. A negative index counts from the
    /// end, as Ruby's string methods do.
    fn insert(&self, index: i64, chunk: String) -> Result<String, Error> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let text = chunk.clone();
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let t = resolve_text(&txn, kind, root, path)
                .ok_or_else(|| "text no longer exists".to_string())?;
            let at = clamp(index, t.len(&txn));
            t.insert(&mut txn, at, &text);
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(chunk)
    }

    /// The name of the root this text lives under.
    fn root_name(&self) -> String {
        self.root.clone()
    }

    /// The Yjs relative position of `index` as the `{type, tname, item, assoc}`
    /// hash editors put in awareness as a caret. `assoc` is "after" (the
    /// default) or "before". Past the end the position names the text itself.
    fn native_relative_position(&self, index: i64, assoc: String) -> Result<RHash, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let assoc = if assoc == "before" {
            Assoc::Before
        } else {
            Assoc::After
        };
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let (pos, assoc) = nogvl(move || -> Result<(RelPos, i32), String> {
            let txn = doc.transact();
            let text = resolve_text(&txn, kind, root, path)
                .ok_or_else(|| "text no longer exists".to_string())?;
            let at = clamp(index, text.len(&txn));
            let sticky = text
                .sticky_index(&txn, at, assoc)
                .unwrap_or_else(|| StickyIndex::from_type(&txn, &text, assoc));
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

    /// Remove `length` units from `index`. Both are clamped, so deleting past
    /// the end removes what is there rather than raising.
    fn delete(&self, index: i64, length: i64) -> Result<(), Error> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let t = resolve_text(&txn, kind, root, path)
                .ok_or_else(|| "text no longer exists".to_string())?;
            let len = t.len(&txn);
            let at = clamp(index, len);
            let count = length.max(0).min((len - at) as i64) as u32;
            if count > 0 {
                t.remove_range(&mut txn, at, count);
            }
            Ok(())
        })
        .map_err(yrb_error)
    }

    fn clear(&self) {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let mut txn = doc.transact_mut();
            if let Some(t) = resolve_text(&txn, kind, root, path) {
                let len = t.len(&txn);
                if len > 0 {
                    t.remove_range(&mut txn, 0, len);
                }
            }
        });
    }
}

/// Ensure a root text exists and return a live handle. Called by
/// `Y::Doc#get_text`.
pub fn root_text(doc: &Doc, name: String) -> RbText {
    let d = doc.clone();
    let root = name.clone();
    nogvl(move || {
        d.get_or_insert_text(root.as_str());
    });
    RbText::root(doc.clone(), name)
}

pub fn define(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    let class = module.define_class("Text", ruby.class_object())?;
    class.define_method("to_s", magnus::method!(RbText::to_s, 0))?;
    class.define_method("to_str", magnus::method!(RbText::to_s, 0))?;
    class.define_method("push", magnus::method!(RbText::push, 1))?;
    class.define_method("<<", magnus::method!(RbText::push, 1))?;
    class.define_method("insert", magnus::method!(RbText::insert, 2))?;
    class.define_method("delete", magnus::method!(RbText::delete, 2))?;
    class.define_method("clear", magnus::method!(RbText::clear, 0))?;
    class.define_method("length", magnus::method!(RbText::length, 0))?;
    class.define_method("size", magnus::method!(RbText::length, 0))?;
    class.define_method("empty?", magnus::method!(RbText::is_empty, 0))?;
    class.define_method("root_name", magnus::method!(RbText::root_name, 0))?;
    class.define_method(
        "native_relative_position",
        magnus::method!(RbText::native_relative_position, 2),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamp_maps_negative_indexes_from_the_end() {
        assert_eq!(clamp(0, 5), 0);
        assert_eq!(clamp(3, 5), 3);
        assert_eq!(clamp(-1, 5), 4);
        assert_eq!(clamp(-5, 5), 0);
    }

    #[test]
    fn clamp_never_leaves_the_range() {
        assert_eq!(clamp(99, 5), 5);
        assert_eq!(clamp(-99, 5), 0);
        assert_eq!(clamp(0, 0), 0);
    }

    #[test]
    fn resolve_finds_a_text_root() {
        let doc = Doc::new();
        let text = doc.get_or_insert_text("body");
        {
            let mut txn = doc.transact_mut();
            text.insert(&mut txn, 0, "hello");
        }
        let txn = doc.transact();
        let t = resolve_text(&txn, Root::Text, "body", &[]).unwrap();
        assert_eq!(t.get_string(&txn), "hello");
    }

    #[test]
    fn resolve_none_when_the_root_is_another_type() {
        let doc = Doc::new();
        doc.get_or_insert_array("body");
        let txn = doc.transact();
        assert!(resolve_text(&txn, Root::Array, "body", &[]).is_none());
    }
}
