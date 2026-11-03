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

use magnus::{prelude::*, typed_data::Obj, Error, Ruby, Value};
use yrs::branch::BranchID;
use yrs::{Any, Array, ArrayRef, Doc, TextPrelim, Transact};

use crate::map::RbMap;
use crate::nogvl;
use crate::read::out_to_any;
use crate::shared::{
    any_to_ruby, element_index, guarded, identity, insert_index, resolve, ruby_to_invalue, to_in,
    Child, ORIGIN,
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
    fn child(&self, index: i64) -> Result<Child, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            Child::of(
                resolve::<ArrayRef, _>(&txn, id)
                    .and_then(|a| a.get(&txn, element_index(index, a.len(&txn))?)),
            )
        })
    }

    // --- reads ---

    /// `array[i]`: a snapshot value. Nested maps and arrays come back as deep
    /// `Hash`/`Array`; use `get_map` for a live handle instead.
    fn get(&self, index: i64) -> Result<Value, Error> {
        let (doc, id) = (&self.doc, &self.id);
        let got: Option<Any> = nogvl(move || {
            let txn = doc.transact();
            let a = resolve::<ArrayRef, _>(&txn, id)?;
            let i = element_index(index, a.len(&txn))?;
            a.get(&txn, i).map(|v| out_to_any(&txn, &v))
        })?;
        let ruby = Ruby::get().unwrap();
        Ok(match got {
            Some(a) => any_to_ruby(&ruby, &a),
            None => ruby.qnil().as_value(),
        })
    }

    /// A live `Y::Map` for the element at `index`, or `nil` if that element is
    /// absent or is not a map. Mutating it mutates the document.
    fn get_map(&self, index: i64) -> Result<Option<RbMap>, Error> {
        Ok(match self.child(index)? {
            Child::Map(id) => Some(RbMap::new(self.doc.clone(), id)),
            _ => None,
        })
    }

    /// A live `Y::Text` for text stored at `index`. An agent appending to one
    /// field of one record goes through here.
    fn get_text(&self, index: i64) -> Result<Option<RbText>, Error> {
        Ok(match self.child(index)? {
            Child::Text(id) => Some(RbText::new(self.doc.clone(), id)),
            _ => None,
        })
    }

    /// A live `Y::Array` for a nested array at `index`.
    fn get_array(&self, index: i64) -> Result<Option<Self>, Error> {
        Ok(match self.child(index)? {
            Child::Array(id) => Some(RbArray::new(self.doc.clone(), id)),
            _ => None,
        })
    }

    fn size(&self) -> Result<usize, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<ArrayRef, _>(&txn, id)
                .map(|a| a.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn is_empty(&self) -> Result<bool, Error> {
        Ok(self.size()? == 0)
    }

    fn snapshot(&self) -> Result<Vec<Any>, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            match resolve::<ArrayRef, _>(&txn, id) {
                Some(a) => a.iter(&txn).map(|v| out_to_any(&txn, &v)).collect(),
                None => Vec::new(),
            }
        })
    }

    fn to_a(&self) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        Ok(ruby
            .ary_from_iter(self.snapshot()?.iter().map(|v| any_to_ruby(&ruby, v)))
            .as_value())
    }

    /// `each { |value| }`: yields a snapshot of each element (read under
    /// `nogvl`, yielded with the GVL held so the block can call into Ruby),
    /// and returns the array. Without a block, an Enumerator.
    fn each(ruby: &Ruby, rb_self: Obj<Self>) -> Result<Value, Error> {
        if !ruby.block_given() {
            return Ok(rb_self.enumeratorize("each", ()).as_value());
        }
        let block = ruby.block_proc()?;
        for v in &rb_self.snapshot()? {
            let _: Value = block.call((any_to_ruby(ruby, v),))?;
        }
        Ok(rb_self.as_value())
    }

    // --- writes ---

    /// Append a value and return the array, as `Array#push` does. A Ruby
    /// `Hash` becomes a real nested `Y.Map`, so the element can be handed back
    /// later as a live handle by `get_map`.
    fn push(rb_self: Obj<Self>, value: Value) -> Result<Obj<Self>, Error> {
        rb_self.insert_at(-1, value)?;
        Ok(rb_self)
    }

    /// Insert at `index` and return the array, as `Array#insert` does.
    fn insert(rb_self: Obj<Self>, index: i64, value: Value) -> Result<Obj<Self>, Error> {
        rb_self.insert_at(index, value)?;
        Ok(rb_self)
    }

    /// Insert at `index`: a negative index counts from the end (-1 appends),
    /// and an index past the end appends.
    fn insert_at(&self, index: i64, value: Value) -> Result<(), Error> {
        let ruby = Ruby::get().unwrap();
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let a = resolve::<ArrayRef, _>(&txn, id).ok_or("array no longer exists")?;
            let at = insert_index(index, a.len(&txn));
            a.insert(&mut txn, at, to_in(iv));
            Ok(())
        })
    }

    /// Insert a new `Y.Text` holding `content` at `index` (the same index
    /// rules as `insert`) and return a live handle to it.
    fn insert_text(&self, index: i64, content: String) -> Result<RbText, Error> {
        let (doc, id) = (&self.doc, &self.id);
        let text = guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let a = resolve::<ArrayRef, _>(&txn, id).ok_or("array no longer exists")?;
            let at = insert_index(index, a.len(&txn));
            Ok(identity(&a.insert(&mut txn, at, TextPrelim::new(content))))
        })?;
        Ok(RbText::new(self.doc.clone(), text))
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
pub fn root_array(doc: &Doc, name: String) -> Result<RbArray, Error> {
    let d = doc.clone();
    let id = nogvl(move || identity(&d.get_or_insert_array(name.as_str())))?;
    Ok(RbArray::new(doc.clone(), id))
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
    class.define_method(
        "native_insert_text",
        magnus::method!(RbArray::insert_text, 2),
    )?;
    class.define_method("delete_at", magnus::method!(RbArray::delete_at, 1))?;
    class.define_method("clear", magnus::method!(RbArray::clear, 0))?;
    class.define_method("size", magnus::method!(RbArray::size, 0))?;
    class.define_method("length", magnus::method!(RbArray::size, 0))?;
    class.define_method("empty?", magnus::method!(RbArray::is_empty, 0))?;
    class.define_method("to_a", magnus::method!(RbArray::to_a, 0))?;
    class.define_method("each", magnus::method!(RbArray::each, 0))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    //! Each method on a handle, called as Ruby calls it.
    use super::*;
    use crate::shared::test_support::{doc, hash, int, rb};
    use rb_sys_test_helpers::ruby_test;
    use yrs::{ArrayPrelim, TextPrelim, Transact};

    fn list_of(values: &[i64]) -> RbArray {
        let list = root_array(&doc(), "list".into()).unwrap();
        for v in values {
            list.insert_at(-1, rb(*v)).unwrap();
        }
        list
    }

    #[ruby_test]
    fn a_fresh_array_is_empty() {
        let list = list_of(&[]);
        assert_eq!(list.size().unwrap(), 0);
        assert!(list.is_empty().unwrap());
        assert_eq!(list.to_a().unwrap().inspect(), "[]");
    }

    #[ruby_test]
    fn insert_at_minus_one_appends() {
        let list = list_of(&[1]);
        list.insert_at(-1, rb(2)).unwrap();
        assert_eq!(list.snapshot().unwrap(), vec![int(1), int(2)]);
    }

    #[ruby_test]
    fn insert_reads_a_negative_index_from_the_end_and_clamps() {
        let list = list_of(&[1, 3]);
        list.insert_at(1, rb(2)).unwrap();
        list.insert_at(-1, rb(4)).unwrap();
        list.insert_at(99, rb(5)).unwrap();
        list.insert_at(-99, rb(0)).unwrap();
        assert_eq!(
            list.snapshot().unwrap(),
            vec![int(0), int(1), int(2), int(3), int(4), int(5)]
        );
    }

    #[ruby_test]
    fn get_reads_a_negative_index_and_is_nil_outside() {
        let list = list_of(&[1, 2, 3]);
        assert_eq!(list.get(0).unwrap().inspect(), "1");
        assert_eq!(list.get(-1).unwrap().inspect(), "3");
        assert_eq!(list.get(3).unwrap().inspect(), "nil");
        assert_eq!(list.get(-4).unwrap().inspect(), "nil");
    }

    #[ruby_test]
    fn set_replaces_in_place_and_raises_outside() {
        let list = list_of(&[1, 2]);
        list.set(-1, rb(9)).unwrap();
        assert_eq!(list.snapshot().unwrap(), vec![int(1), int(9)]);
        let err = list.set(2, rb(3)).unwrap_err();
        assert!(err.to_string().contains("index out of range"), "{err}");
    }

    #[ruby_test]
    fn delete_at_returns_the_removed_value_or_nil() {
        let list = list_of(&[1, 2, 3]);
        assert_eq!(list.delete_at(1).unwrap().inspect(), "2");
        assert_eq!(list.delete_at(5).unwrap().inspect(), "nil");
        assert_eq!(list.snapshot().unwrap(), vec![int(1), int(3)]);
    }

    #[ruby_test]
    fn clear_removes_every_element() {
        let list = list_of(&[1, 2, 3]);
        list.clear().unwrap();
        assert!(list.is_empty().unwrap());
    }

    #[ruby_test]
    fn child_is_the_shared_value_at_an_index() {
        let list = list_of(&[1]);
        list.insert_at(-1, hash(&[("name", rb("Ada"))]).as_value())
            .unwrap();
        assert!(matches!(list.child(-1).unwrap(), Child::Map(_)));
        assert!(matches!(list.child(0).unwrap(), Child::Other));
        assert!(matches!(list.child(2).unwrap(), Child::Other));
    }

    #[ruby_test]
    fn get_map_get_text_and_get_array_narrow_by_type() {
        let list = list_of(&[]);
        list.insert_at(-1, hash(&[("name", rb("Ada"))]).as_value())
            .unwrap();
        {
            let mut txn = list.doc.transact_mut();
            let array = resolve::<ArrayRef, _>(&txn, &list.id).unwrap();
            array.push_back(&mut txn, TextPrelim::new("hi"));
            array.push_back(&mut txn, ArrayPrelim::default());
        }
        assert!(list.get_map(0).unwrap().is_some());
        assert_eq!(list.get(0).unwrap().inspect(), r#"{"name" => "Ada"}"#);
        assert!(list.get_text(0).unwrap().is_none());
        assert!(list.get_text(1).unwrap().is_some());
        assert!(list.get_map(1).unwrap().is_none());
        let nested = list.get_array(-1).unwrap().expect("an array at the end");
        nested.insert_at(-1, rb(7)).unwrap();
        assert_eq!(list.get(2).unwrap().inspect(), "[7]");
    }

    #[ruby_test]
    fn a_handle_to_a_deleted_array_reads_empty_and_refuses_writes() {
        let outer = list_of(&[]);
        {
            let mut txn = outer.doc.transact_mut();
            let array = resolve::<ArrayRef, _>(&txn, &outer.id).unwrap();
            array.push_back(&mut txn, ArrayPrelim::default());
        }
        let inner = outer.get_array(0).unwrap().unwrap();
        inner.insert_at(-1, rb(1)).unwrap();
        outer.delete_at(0).unwrap();
        assert_eq!(inner.size().unwrap(), 0);
        assert!(inner.snapshot().unwrap().is_empty());
        let err = inner.insert_at(-1, rb(2)).unwrap_err();
        assert!(err.to_string().contains("array no longer exists"), "{err}");
    }

    #[ruby_test]
    fn root_array_returns_the_same_array_for_a_name() {
        let doc = doc();
        root_array(&doc, "list".into())
            .unwrap()
            .insert_at(-1, rb(1))
            .unwrap();
        assert_eq!(
            root_array(&doc, "list".into()).unwrap().snapshot().unwrap(),
            vec![int(1)]
        );
    }
}
