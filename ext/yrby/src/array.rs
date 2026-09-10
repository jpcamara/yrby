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
//! without an index-addressed handle you could read one but never edit it in
//! place.

use magnus::{prelude::*, Error, Ruby, Value};
use yrs::{Any, Array, Doc, Out, Transact};

use crate::map::RbMap;
use crate::read::out_to_any;
use crate::shared::{any_to_ruby, resolve_array, ruby_to_invalue, to_in, Root, Seg};
use crate::text::RbText;
use crate::{nogvl, yrb_error};

#[magnus::wrap(class = "Y::Array", free_immediately, size)]
pub struct RbArray {
    doc: Doc,
    kind: Root,
    root: String,
    path: Vec<Seg>,
}

/// Ruby index semantics: a negative index counts from the end. Returns `None`
/// when the index falls outside the array, which every caller turns into `nil`
/// or a no-op rather than an exception.
fn absolute(index: i64, len: u32) -> Option<u32> {
    let len = len as i64;
    let i = if index < 0 { len + index } else { index };
    (i >= 0 && i < len).then_some(i as u32)
}

impl RbArray {
    pub fn root(doc: Doc, root: String) -> Self {
        RbArray {
            doc,
            kind: Root::Array,
            root,
            path: Vec::new(),
        }
    }

    pub fn at(doc: Doc, kind: Root, root: String, path: Vec<Seg>) -> Self {
        RbArray {
            doc,
            kind,
            root,
            path,
        }
    }

    // --- reads ---

    /// `array[i]`: a snapshot value. Nested maps and arrays come back as deep
    /// `Hash`/`Array`; use `get_map` for a live handle instead.
    fn get(&self, index: i64) -> Value {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let got: Option<Any> = nogvl(move || {
            let txn = doc.transact();
            let a = resolve_array(&txn, kind, root, path)?;
            let i = absolute(index, a.len(&txn))?;
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
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let resolved: Option<u32> = nogvl(move || {
            let txn = doc.transact();
            let a = resolve_array(&txn, kind, root, path)?;
            let i = absolute(index, a.len(&txn))?;
            matches!(a.get(&txn, i), Some(Out::YMap(_))).then_some(i)
        });
        resolved.map(|i| {
            let mut path = self.path.clone();
            path.push(Seg::Index(i));
            RbMap::at(self.doc.clone(), self.kind, self.root.clone(), path)
        })
    }

    /// A live `Y::Text` for text stored at `index`. An agent appending to one
    /// field of one record goes through here.
    fn get_text(&self, index: i64) -> Option<RbText> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let resolved: Option<u32> = nogvl(move || {
            let txn = doc.transact();
            let a = resolve_array(&txn, kind, root, path)?;
            let i = absolute(index, a.len(&txn))?;
            matches!(a.get(&txn, i), Some(Out::YText(_))).then_some(i)
        });
        resolved.map(|i| {
            let mut path = self.path.clone();
            path.push(Seg::Index(i));
            RbText::at(self.doc.clone(), self.kind, self.root.clone(), path)
        })
    }

    /// A live `Y::Array` for a nested array at `index`.
    fn get_array(&self, index: i64) -> Option<Self> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let resolved: Option<u32> = nogvl(move || {
            let txn = doc.transact();
            let a = resolve_array(&txn, kind, root, path)?;
            let i = absolute(index, a.len(&txn))?;
            matches!(a.get(&txn, i), Some(Out::YArray(_))).then_some(i)
        });
        resolved.map(|i| {
            let mut path = self.path.clone();
            path.push(Seg::Index(i));
            RbArray::at(self.doc.clone(), self.kind, self.root.clone(), path)
        })
    }

    fn size(&self) -> usize {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve_array(&txn, kind, root, path)
                .map(|a| a.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn is_empty(&self) -> bool {
        self.size() == 0
    }

    fn snapshot(&self) -> Vec<Any> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            match resolve_array(&txn, kind, root, path) {
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
        let ruby = Ruby::get().unwrap();
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let a = resolve_array(&txn, kind, root, path)
                .ok_or_else(|| "array no longer exists".to_string())?;
            a.push_back(&mut txn, to_in(iv));
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(value)
    }

    /// Insert at `index`. An index past the end appends; a negative index
    /// counts from the end.
    fn insert(&self, index: i64, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let a = resolve_array(&txn, kind, root, path)
                .ok_or_else(|| "array no longer exists".to_string())?;
            let len = a.len(&txn);
            let at = if index < 0 {
                (len as i64 + index).max(0) as u32
            } else {
                (index as u32).min(len)
            };
            a.insert(&mut txn, at, to_in(iv));
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(value)
    }

    /// Remove the element at `index`, returning its previous snapshot value.
    fn delete_at(&self, index: i64) -> Value {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let prev: Option<Any> = nogvl(move || {
            let mut txn = doc.transact_mut();
            let a = resolve_array(&txn, kind, root, path)?;
            let i = absolute(index, a.len(&txn))?;
            // Convert before removing: a removed shared ref would dangle.
            let prev = a.get(&txn, i).map(|v| out_to_any(&txn, &v));
            a.remove(&mut txn, i);
            prev
        });
        let ruby = Ruby::get().unwrap();
        match prev {
            Some(a) => any_to_ruby(&ruby, &a),
            None => ruby.qnil().as_value(),
        }
    }

    fn clear(&self) {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let mut txn = doc.transact_mut();
            if let Some(a) = resolve_array(&txn, kind, root, path) {
                let len = a.len(&txn);
                if len > 0 {
                    a.remove_range(&mut txn, 0, len);
                }
            }
        });
    }

    /// Replace the element at `index`. Yjs arrays have no in-place update, so
    /// this is a remove plus an insert in one transaction. The element gets a
    /// new identity, which is why a live handle to it must be re-fetched.
    fn set(&self, index: i64, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let a = resolve_array(&txn, kind, root, path)
                .ok_or_else(|| "array no longer exists".to_string())?;
            let i = absolute(index, a.len(&txn)).ok_or_else(|| "index out of range".to_string())?;
            a.remove(&mut txn, i);
            a.insert(&mut txn, i, to_in(iv));
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(value)
    }
}

/// Ensure a root array exists and return a live handle. Called by
/// `Y::Doc#get_array`.
pub fn root_array(doc: &Doc, name: String) -> RbArray {
    let d = doc.clone();
    let root = name.clone();
    nogvl(move || {
        d.get_or_insert_array(root.as_str());
    });
    RbArray::root(doc.clone(), name)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absolute_maps_negative_indexes_from_the_end() {
        assert_eq!(absolute(0, 3), Some(0));
        assert_eq!(absolute(2, 3), Some(2));
        assert_eq!(absolute(-1, 3), Some(2));
        assert_eq!(absolute(-3, 3), Some(0));
    }

    #[test]
    fn absolute_rejects_out_of_range() {
        assert_eq!(absolute(3, 3), None);
        assert_eq!(absolute(-4, 3), None);
        assert_eq!(absolute(0, 0), None);
    }

    #[test]
    fn resolve_finds_a_map_nested_in_an_array() {
        // The shape this type exists for: a list of records, addressed by index.
        use yrs::{Map, MapPrelim};
        let doc = Doc::new();
        let arr = doc.get_or_insert_array("plan");
        {
            let mut txn = doc.transact_mut();
            let step = arr.push_back(&mut txn, MapPrelim::default());
            step.insert(&mut txn, "status", "pending");
        }
        let txn = doc.transact();
        let step = crate::shared::resolve_map(&txn, Root::Array, "plan", &[Seg::Index(0)]).unwrap();
        assert!(matches!(
            step.get(&txn, "status"),
            Some(Out::Any(Any::String(_)))
        ));
    }

    #[test]
    fn resolve_none_when_index_is_not_a_map() {
        let doc = Doc::new();
        let arr = doc.get_or_insert_array("plan");
        {
            let mut txn = doc.transact_mut();
            arr.push_back(&mut txn, 5_i64);
        }
        let txn = doc.transact();
        assert!(crate::shared::resolve_map(&txn, Root::Array, "plan", &[Seg::Index(0)]).is_none());
        assert!(crate::shared::resolve_map(&txn, Root::Array, "plan", &[Seg::Index(9)]).is_none());
    }
}
