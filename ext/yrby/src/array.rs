//! Live `Y::Array` handles over a yrs `Array`: read and write the elements of a
//! shared list from Ruby.
//!
//! Same contract as `Y::Map`. Every operation opens its own transaction inside
//! `nogvl`, nothing caches a branch pointer, and Ruby values are only touched
//! with the GVL held.
//!
//! The method that earns this type its place is `get_map`, which hands back a
//! live handle to a map stored at an index. A list of records is the shape most
//! collaborative state actually has (a plan, a board, a set of rows), and
//! without a handle you could read one but never edit it in place. The handle
//! keeps the record's identity, so it stays on that record when others are
//! inserted or removed around it.

use magnus::{prelude::*, Error, Ruby, Value};
use yrs::branch::BranchID;
use yrs::{Any, Array, ArrayRef, Doc, Out, Transact};

use crate::map::RbMap;
use crate::nogvl;
use crate::read::out_to_any;
use crate::shared::{
    any_to_ruby, element_index, guarded, identity, insert_index, resolve, ruby_to_invalue, to_in,
    ORIGIN,
};
use crate::text::RbText;

#[magnus::wrap(class = "Y::Array", free_immediately, size)]
pub struct RbArray {
    doc: Doc,
    id: BranchID,
}

impl RbArray {
    pub fn new(doc: Doc, id: BranchID) -> Self {
        RbArray { doc, id }
    }

    /// The shared value at `index`, resolved now: what `get_map`, `get_array`
    /// and `get_text` narrow to a handle.
    fn child(&self, index: i64) -> Option<Out> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            let a = resolve::<ArrayRef, _>(&txn, id)?;
            a.get(&txn, element_index(index, a.len(&txn))?)
        })
    }

    // --- reads ---

    /// `array[i]`: a snapshot value. Nested maps and arrays come back as deep
    /// `Hash`/`Array`; use `get_map` for a live handle instead.
    fn get(&self, index: i64) -> Value {
        let (doc, id) = (&self.doc, &self.id);
        let got: Option<Any> = nogvl(move || {
            let txn = doc.transact();
            let a = resolve::<ArrayRef, _>(&txn, id)?;
            let i = element_index(index, a.len(&txn))?;
            a.get(&txn, i).map(|v| out_to_any(&txn, &v))
        });
        let ruby = Ruby::get().unwrap();
        match got {
            Some(a) => any_to_ruby(&ruby, &a),
            None => ruby.qnil().as_value(),
        }
    }

    /// A live `Y::Map` for the element at `index`, or `nil` if that element is
    /// absent or is not a map. Mutating it mutates the document.
    fn get_map(&self, index: i64) -> Option<RbMap> {
        match self.child(index)? {
            Out::YMap(m) => Some(RbMap::new(self.doc.clone(), identity(&m))),
            _ => None,
        }
    }

    /// A live `Y::Text` for text stored at `index`. An agent appending to one
    /// field of one record goes through here.
    fn get_text(&self, index: i64) -> Option<RbText> {
        match self.child(index)? {
            Out::YText(t) => Some(RbText::new(self.doc.clone(), identity(&t))),
            _ => None,
        }
    }

    /// A live `Y::Array` for a nested array at `index`.
    fn get_array(&self, index: i64) -> Option<Self> {
        match self.child(index)? {
            Out::YArray(a) => Some(RbArray::new(self.doc.clone(), identity(&a))),
            _ => None,
        }
    }

    fn size(&self) -> usize {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<ArrayRef, _>(&txn, id)
                .map(|a| a.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn is_empty(&self) -> bool {
        self.size() == 0
    }

    fn snapshot(&self) -> Vec<Any> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            match resolve::<ArrayRef, _>(&txn, id) {
                Some(a) => a.iter(&txn).map(|v| out_to_any(&txn, &v)).collect(),
                None => Vec::new(),
            }
        })
    }

    fn to_a(&self) -> Value {
        let ruby = Ruby::get().unwrap();
        ruby.ary_from_iter(self.snapshot().iter().map(|v| any_to_ruby(&ruby, v)))
            .as_value()
    }

    /// `each { |value| }`: yields a snapshot of each element (read under
    /// `nogvl`, yielded with the GVL held so the block can call into Ruby).
    fn each(&self) -> Result<(), Error> {
        let ruby = Ruby::get().unwrap();
        let block = ruby.block_proc()?;
        for v in &self.snapshot() {
            let _: Value = block.call((any_to_ruby(&ruby, v),))?;
        }
        Ok(())
    }

    // --- writes ---

    /// Append a value. A Ruby `Hash` becomes a real nested `Y.Map`, so the
    /// element can be handed back later as a live handle by `get_map`.
    fn push(&self, value: Value) -> Result<Value, Error> {
        self.insert(-1, value)
    }

    /// Insert at `index`, as `Array#insert` does: a negative index counts from
    /// the end (-1 appends). An index past the end appends.
    fn insert(&self, index: i64, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let a = resolve::<ArrayRef, _>(&txn, id).ok_or("array no longer exists")?;
            let at = insert_index(index, a.len(&txn));
            a.insert(&mut txn, at, to_in(iv));
            Ok(())
        })?;
        Ok(value)
    }

    /// Remove the element at `index`, returning its previous snapshot value.
    fn delete_at(&self, index: i64) -> Result<Value, Error> {
        let (doc, id) = (&self.doc, &self.id);
        let prev: Option<Any> = guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let Some(a) = resolve::<ArrayRef, _>(&txn, id) else {
                return Ok(None);
            };
            let Some(i) = element_index(index, a.len(&txn)) else {
                return Ok(None);
            };
            // Convert before removing: a removed shared ref would dangle.
            let prev = a.get(&txn, i).map(|v| out_to_any(&txn, &v));
            a.remove(&mut txn, i);
            Ok(prev)
        })?;
        let ruby = Ruby::get().unwrap();
        Ok(match prev {
            Some(a) => any_to_ruby(&ruby, &a),
            None => ruby.qnil().as_value(),
        })
    }

    fn clear(&self) -> Result<(), Error> {
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            if let Some(a) = resolve::<ArrayRef, _>(&txn, id) {
                let len = a.len(&txn);
                if len > 0 {
                    a.remove_range(&mut txn, 0, len);
                }
            }
            Ok(())
        })
    }

    /// Replace the element at `index`. Yjs arrays have no in-place update, so
    /// this is a remove plus an insert in one transaction. The element gets a
    /// new identity, which is why a live handle to it must be re-fetched.
    fn set(&self, index: i64, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let a = resolve::<ArrayRef, _>(&txn, id).ok_or("array no longer exists")?;
            let i = element_index(index, a.len(&txn)).ok_or("index out of range")?;
            a.remove(&mut txn, i);
            a.insert(&mut txn, i, to_in(iv));
            Ok(())
        })?;
        Ok(value)
    }
}

/// Ensure a root array exists and return a live handle. Called by
/// `Y::Doc#get_array`.
pub fn root_array(doc: &Doc, name: String) -> RbArray {
    let d = doc.clone();
    let id = nogvl(move || identity(&d.get_or_insert_array(name.as_str())));
    RbArray::new(doc.clone(), id)
}

pub fn define(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    let class = module.define_class("Array", ruby.class_object())?;
    class.define_method("[]", magnus::method!(RbArray::get, 1))?;
    class.define_method("get", magnus::method!(RbArray::get, 1))?;
    class.define_method("[]=", magnus::method!(RbArray::set, 2))?;
    class.define_method("get_map", magnus::method!(RbArray::get_map, 1))?;
    class.define_method("get_array", magnus::method!(RbArray::get_array, 1))?;
    class.define_method("get_text", magnus::method!(RbArray::get_text, 1))?;
    class.define_method("push", magnus::method!(RbArray::push, 1))?;
    class.define_method("<<", magnus::method!(RbArray::push, 1))?;
    class.define_method("insert", magnus::method!(RbArray::insert, 2))?;
    class.define_method("delete_at", magnus::method!(RbArray::delete_at, 1))?;
    class.define_method("clear", magnus::method!(RbArray::clear, 0))?;
    class.define_method("size", magnus::method!(RbArray::size, 0))?;
    class.define_method("length", magnus::method!(RbArray::size, 0))?;
    class.define_method("empty?", magnus::method!(RbArray::is_empty, 0))?;
    class.define_method("to_a", magnus::method!(RbArray::to_a, 0))?;
    class.define_method("each", magnus::method!(RbArray::each, 0))?;
    Ok(())
}
