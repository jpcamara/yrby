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

use magnus::{prelude::*, Error, RHash, Ruby};
use yrs::branch::{Branch, BranchID, BranchPtr};
use yrs::{Assoc, Doc, GetString, IndexedSequence, StickyIndex, Text, TextRef, Transact};

use crate::nogvl;
use crate::shared::{
    char_len, delete_span, guarded, identity, insert_index, resolve, to_chars, to_units, Position,
    ORIGIN,
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

    fn to_s(&self) -> String {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<TextRef, _>(&txn, id)
                .map(|t| t.get_string(&txn))
                .unwrap_or_default()
        })
    }

    /// The length in characters, as `String#length` counts.
    fn length(&self) -> usize {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<TextRef, _>(&txn, id)
                .map(|t| char_len(&txn, &t) as usize)
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
        let (doc, id) = (&self.doc, &self.id);
        let text = chunk.clone();
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let t = resolve::<TextRef, _>(&txn, id).ok_or("text no longer exists")?;
            let at = t.len(&txn);
            t.insert(&mut txn, at, &text);
            Ok(())
        })?;
        Ok(chunk)
    }

    /// Insert at character `index`, as `String#insert` does: a negative index
    /// counts from the end (-1 appends). Clamped into range.
    fn insert(&self, index: i64, chunk: String) -> Result<String, Error> {
        let (doc, id) = (&self.doc, &self.id);
        let text = chunk.clone();
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let t = resolve::<TextRef, _>(&txn, id).ok_or("text no longer exists")?;
            let at = to_units(&txn, &t, insert_index(index, char_len(&txn, &t)));
            t.insert(&mut txn, at, &text);
            Ok(())
        })?;
        Ok(chunk)
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
        Ok(nogvl(move || {
            let txn = doc.transact();
            let text = resolve::<TextRef, _>(&txn, id)?;
            let offset = sticky.get_offset(&txn)?;
            let branch: &Branch = text.as_ref();
            (BranchPtr::from(branch) == offset.branch).then(|| to_chars(&txn, &text, offset.index))
        }))
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
pub fn root_text(doc: &Doc, name: String) -> RbText {
    let d = doc.clone();
    let id = nogvl(move || identity(&d.get_or_insert_text(name.as_str())));
    RbText::new(doc.clone(), id)
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
