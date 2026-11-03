//! Live `Y::Text` handles over a yrs `Text`: append and edit shared text from
//! Ruby.
//!
//! Same contract as the other handles: a transaction per operation inside
//! `nogvl`, the branch resolved from its identity each time, Ruby touched only
//! with the GVL held. Indexes are Ruby characters (see `shared`).
//!
//! This is the type an agent streams into. `push` is the hot path, and it is a
//! CRDT insert at the current end rather than a whole-document write, so a
//! person typing in the same paragraph while the agent appends does not lose
//! their edit and neither does the agent.

use magnus::{prelude::*, typed_data::Obj, Error, RHash, Ruby};
use yrs::branch::{Branch, BranchID, BranchPtr};
use yrs::{Assoc, Doc, GetString, IndexedSequence, StickyIndex, Text, TextRef, Transact};

use crate::nogvl;
use crate::shared::{
    char_len, delete_span, end_or_units, guarded, identity, insert_index, resolve, to_chars,
    to_units, Position, ORIGIN,
};
use crate::yrb_error;

#[magnus::wrap(class = "Y::Text", free_immediately, size)]
pub struct RbText {
    doc: Doc,
    id: BranchID,
}

impl RbText {
    pub fn new(doc: Doc, id: BranchID) -> Self {
        RbText { doc, id }
    }

    // --- reads ---

    fn to_s(&self) -> Result<String, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<TextRef, _>(&txn, id)
                .map(|t| t.get_string(&txn))
                .unwrap_or_default()
        })
    }

    /// The length in characters, as `String#length` counts.
    fn length(&self) -> Result<usize, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<TextRef, _>(&txn, id)
                .map(|t| char_len(&txn, &t) as usize)
                .unwrap_or(0)
        })
    }

    fn is_empty(&self) -> Result<bool, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<TextRef, _>(&txn, id).is_none_or(|t| t.len(&txn) == 0)
        })
    }

    // --- writes ---

    /// Append to the end and return the text, as `String#<<` does. The
    /// operation an agent streaming output performs over and over, so it stays
    /// a single insert at the current length.
    fn push(rb_self: Obj<Self>, chunk: String) -> Result<Obj<Self>, Error> {
        rb_self.insert_at(-1, chunk)?;
        Ok(rb_self)
    }

    /// Insert at character `index` and return the text, as `String#insert`
    /// does.
    fn insert(rb_self: Obj<Self>, index: i64, chunk: String) -> Result<Obj<Self>, Error> {
        rb_self.insert_at(index, chunk)?;
        Ok(rb_self)
    }

    /// Insert at character `index`: a negative index counts from the end (-1
    /// appends). Clamped into range.
    fn insert_at(&self, index: i64, text: String) -> Result<(), Error> {
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let t = resolve::<TextRef, _>(&txn, id).ok_or("text no longer exists")?;
            let at = end_or_units(&txn, &t, index);
            t.insert(&mut txn, at, &text);
            Ok(())
        })
    }

    /// The Yjs relative position of character `index` as the `{type, tname,
    /// item, assoc}` hash editors put in awareness as a caret. `assoc` is
    /// "after" (the default) or "before". Past the end the position names the
    /// text itself.
    fn native_relative_position(&self, index: i64, assoc: String) -> Result<RHash, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let assoc = if assoc == "before" {
            Assoc::Before
        } else {
            Assoc::After
        };
        let (doc, id) = (&self.doc, &self.id);
        let position = guarded(move || {
            let txn = doc.transact();
            let text = resolve::<TextRef, _>(&txn, id).ok_or("text no longer exists")?;
            let at = to_units(&txn, &text, insert_index(index, char_len(&txn, &text)));
            let sticky = text
                .sticky_index(&txn, at, assoc)
                .unwrap_or_else(|| StickyIndex::from_type(&txn, &text, assoc));
            Ok(Position::new(sticky))
        })?;
        position.to_ruby(&ruby)
    }

    /// The character index a relative position (a peer's caret from
    /// awareness, or one from `relative_position`) falls at in this text now,
    /// or nil when it points somewhere else or its item is gone.
    fn index_at(&self, position: RHash) -> Result<Option<u32>, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let sticky = crate::sticky_from_ruby(&ruby, position)?;
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            let text = resolve::<TextRef, _>(&txn, id)?;
            let offset = sticky.get_offset(&txn)?;
            let branch: &Branch = text.as_ref();
            (BranchPtr::from(branch) == offset.branch).then(|| to_chars(&txn, &text, offset.index))
        })
    }

    /// Remove `length` characters from `index`, as `String#slice!` does: a
    /// negative index counts from the end, and the length stops at the end.
    fn delete(&self, index: i64, length: i64) -> Result<(), Error> {
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let t = resolve::<TextRef, _>(&txn, id).ok_or("text no longer exists")?;
            if let Some((from, to)) = delete_span(index, length, char_len(&txn, &t)) {
                let (from, to) = (to_units(&txn, &t, from), to_units(&txn, &t, to));
                if to > from {
                    t.remove_range(&mut txn, from, to - from);
                }
            }
            Ok(())
        })
    }

    fn clear(&self) -> Result<(), Error> {
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            if let Some(t) = resolve::<TextRef, _>(&txn, id) {
                let len = t.len(&txn);
                if len > 0 {
                    t.remove_range(&mut txn, 0, len);
                }
            }
            Ok(())
        })
    }
}

/// Ensure a root text exists and return a live handle. Called by
/// `Y::Doc#get_text`.
pub fn root_text(doc: &Doc, name: String) -> Result<RbText, Error> {
    let d = doc.clone();
    let id = nogvl(move || identity(&d.get_or_insert_text(name.as_str())))?;
    Ok(RbText::new(doc.clone(), id))
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
    class.define_method("index_at", magnus::method!(RbText::index_at, 1))?;
    class.define_private_method(
        "native_relative_position",
        magnus::method!(RbText::native_relative_position, 2),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    //! Each method on a handle, called as Ruby calls it. Indexes count
    //! characters, as Ruby's do, though the document counts UTF-16 units.
    use super::*;
    use crate::shared::test_support::doc;
    use rb_sys_test_helpers::ruby_test;
    use yrs::{Map, MapRef, TextPrelim, Transact};

    fn text(initial: &str) -> RbText {
        let text = root_text(&doc(), "t".into()).unwrap();
        text.insert_at(-1, initial.into()).unwrap();
        text
    }

    #[ruby_test]
    fn a_fresh_text_is_empty() {
        let t = text("");
        assert_eq!(t.to_s().unwrap(), "");
        assert_eq!(t.length().unwrap(), 0);
        assert!(t.is_empty().unwrap());
    }

    #[ruby_test]
    fn appending_at_minus_one_and_length_counting_characters() {
        let t = text("hé");
        t.insert_at(-1, "😀!".into()).unwrap();
        assert_eq!(t.to_s().unwrap(), "hé😀!");
        assert_eq!(t.length().unwrap(), 4);
    }

    #[ruby_test]
    fn insert_reads_a_negative_index_from_the_end_and_clamps() {
        let t = text("a😀c");
        t.insert_at(2, "b".into()).unwrap();
        t.insert_at(-1, "d".into()).unwrap();
        t.insert_at(99, "e".into()).unwrap();
        t.insert_at(-99, "_".into()).unwrap();
        assert_eq!(t.to_s().unwrap(), "_a😀bcde");
    }

    #[ruby_test]
    fn delete_removes_characters_as_slice_bang_does() {
        let t = text("a😀bcd");
        t.delete(1, 2).unwrap();
        assert_eq!(t.to_s().unwrap(), "acd");
        t.delete(-1, 5).unwrap();
        assert_eq!(t.to_s().unwrap(), "ac");
        t.delete(9, 1).unwrap();
        assert_eq!(t.to_s().unwrap(), "ac");
    }

    #[ruby_test]
    fn clear_removes_everything() {
        let t = text("hello");
        t.clear().unwrap();
        assert!(t.is_empty().unwrap());
    }

    #[ruby_test]
    fn a_relative_position_follows_its_character() {
        let t = text("a😀c");
        let position = t.native_relative_position(2, "after".into()).unwrap();
        assert_eq!(t.index_at(position).unwrap(), Some(2));
        t.insert_at(0, "xy".into()).unwrap();
        assert_eq!(t.index_at(position).unwrap(), Some(4));
    }

    #[ruby_test]
    fn a_position_in_another_text_is_nil() {
        let doc = doc();
        let a = root_text(&doc, "a".into()).unwrap();
        let b = root_text(&doc, "b".into()).unwrap();
        a.insert_at(-1, "one".into()).unwrap();
        b.insert_at(-1, "two".into()).unwrap();
        let position = a.native_relative_position(1, "after".into()).unwrap();
        assert_eq!(b.index_at(position).unwrap(), None);
    }

    #[ruby_test]
    fn a_handle_to_a_deleted_text_reads_empty_and_refuses_writes() {
        let doc = doc();
        let id = {
            let map: MapRef = doc.get_or_insert_map("state");
            let mut txn = doc.transact_mut();
            identity(&map.insert(&mut txn, "notes", TextPrelim::new("hi")))
        };
        let notes = RbText::new(doc.clone(), id);
        assert_eq!(notes.to_s().unwrap(), "hi");
        {
            let map: MapRef = doc.get_or_insert_map("state");
            map.remove(&mut doc.transact_mut(), "notes");
        }
        assert_eq!(notes.to_s().unwrap(), "");
        assert!(notes.is_empty().unwrap());
        let err = notes.insert_at(-1, "more".into()).unwrap_err();
        assert!(err.to_string().contains("text no longer exists"), "{err}");
    }
}
