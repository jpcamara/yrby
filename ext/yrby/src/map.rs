//! Live `Y::Map` handles over a yrs `Map`, exposing read + write of actual
//! shared data (not just opaque CRDT sync).
//!
//! Thread safety mirrors `Y::Doc` exactly: every operation opens its own
//! transaction inside `nogvl` (GVL released) and holds no lock across the GVL
//! boundary. Ruby values are read/built only with the GVL held (before/after the
//! `nogvl` block); the closure works purely on `Send` data.
//!
//! A handle keeps its map's identity and resolves it per operation (see
//! `shared`). Once the map is deleted, reads return empty and writes raise.

use magnus::{prelude::*, typed_data::Obj, Error, Ruby, Value};
use yrs::branch::BranchID;
use yrs::{Any, Doc, Map, MapRef, TextPrelim, Transact};

use crate::array::RbArray;
use crate::nogvl;
use crate::read::out_to_any;
use crate::shared::{
    any_to_ruby, identity, key_to_string, resolve, ruby_to_invalue, to_in, write, Child,
};
use crate::text::RbText;

/// A live handle to a yrs `Map` inside a `Doc`. `Send + Sync` (all fields are),
/// so it satisfies the same thread-safety assertion as `Y::Doc`.
#[magnus::wrap(class = "Y::Map", free_immediately, size)]
pub struct RbMap {
    doc: Doc,
    id: BranchID,
}

impl RbMap {
    pub fn new(doc: Doc, id: BranchID) -> Self {
        RbMap { doc, id }
    }

    /// The shared value at `key`, resolved now: what `get_map`, `get_array`
    /// and `get_text` narrow to a handle.
    fn child(&self, key: Value) -> Result<Child, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            Child::of(resolve::<MapRef, _>(&txn, id).and_then(|m| m.get(&txn, &key)))
        })
    }

    // --- reads ---

    /// `map[key]`: a snapshot Ruby value (primitives; nested map/array become a
    /// deep `Hash`/`Array`). Use `get_map` for a live nested handle.
    fn get(&self, key: Value) -> Result<Value, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        let got: Option<Any> = nogvl(move || {
            let txn = doc.transact();
            let m = resolve::<MapRef, _>(&txn, id)?;
            m.get(&txn, &key).map(|v| out_to_any(&txn, &v))
        })?;
        let ruby = Ruby::get().unwrap();
        Ok(match got {
            Some(a) => any_to_ruby(&ruby, &a),
            None => ruby.qnil().as_value(),
        })
    }

    /// A live `Y::Map` for a nested map at `key`, or `nil` if `key` is absent or
    /// not a map. Mutating it mutates the document.
    fn get_map(&self, key: Value) -> Result<Option<Self>, Error> {
        Ok(match self.child(key)? {
            Child::Map(id) => Some(RbMap::new(self.doc.clone(), id)),
            _ => None,
        })
    }

    /// A live `Y::Array` for an array stored at `key`.
    fn get_array(&self, key: Value) -> Result<Option<RbArray>, Error> {
        Ok(match self.child(key)? {
            Child::Array(id) => Some(RbArray::new(self.doc.clone(), id)),
            _ => None,
        })
    }

    /// A live `Y::Text` for text stored at `key`.
    fn get_text(&self, key: Value) -> Result<Option<RbText>, Error> {
        Ok(match self.child(key)? {
            Child::Text(id) => Some(RbText::new(self.doc.clone(), id)),
            _ => None,
        })
    }

    fn has_key(&self, key: Value) -> Result<bool, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<MapRef, _>(&txn, id)
                .map(|m| m.contains_key(&txn, &key))
                .unwrap_or(false)
        })
    }

    fn size(&self) -> Result<usize, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<MapRef, _>(&txn, id)
                .map(|m| m.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn keys(&self) -> Result<Vec<String>, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            match resolve::<MapRef, _>(&txn, id) {
                Some(m) => m.keys(&txn).map(|k| k.to_string()).collect(),
                None => Vec::new(),
            }
        })
    }

    fn snapshot(&self) -> Result<Vec<(String, Any)>, Error> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            match resolve::<MapRef, _>(&txn, id) {
                Some(m) => m
                    .iter(&txn)
                    .map(|(k, v)| (k.to_string(), out_to_any(&txn, &v)))
                    .collect(),
                None => Vec::new(),
            }
        })
    }

    fn to_h(&self) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        let h = ruby.hash_new();
        for (k, v) in &self.snapshot()? {
            h.aset(k.as_str(), any_to_ruby(&ruby, v))?;
        }
        Ok(h.as_value())
    }

    /// `each { |key, value| }`: yields a snapshot of each entry (read under
    /// `nogvl`, yielded with the GVL held so the block can call back into
    /// Ruby), and returns the map. Without a block, an Enumerator.
    fn each(ruby: &Ruby, rb_self: Obj<Self>) -> Result<Value, Error> {
        if !ruby.block_given() {
            return Ok(rb_self.enumeratorize("each", ()).as_value());
        }
        let block = ruby.block_proc()?;
        for (k, v) in &rb_self.snapshot()? {
            let _: Value = block.call((k.as_str(), any_to_ruby(ruby, v)))?;
        }
        Ok(rb_self.as_value())
    }

    // --- writes ---

    /// `map[key] = value`: store a value. Ruby `Hash` creates a live nested map;
    /// `Array` an embedded array; primitives their `Any` counterpart. Returns the
    /// value assigned (so `map[k] = v` yields `v`, as Ruby expects).
    fn set(&self, key: Value, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        let key = key_to_string(key)?;
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, id) = (&self.doc, &self.id);
        write(doc, move |txn| {
            let m = resolve::<MapRef, _>(txn, id).ok_or("map no longer exists")?;
            m.insert(txn, key, to_in(iv));
            Ok(())
        })?;
        Ok(value)
    }

    /// Store a new `Y.Text` holding `content` at `key`, replacing what was
    /// there, and return a live handle to it. A text in a map is what lets
    /// two people type in the same field and both keep their edit.
    fn set_text(&self, key: Value, content: String) -> Result<RbText, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        let text = write(doc, move |txn| {
            let m = resolve::<MapRef, _>(txn, id).ok_or("map no longer exists")?;
            Ok(identity(&m.insert(txn, key, TextPrelim::new(content))))
        })?;
        Ok(RbText::new(self.doc.clone(), text))
    }

    /// Remove `key`, returning its previous snapshot value (or `nil`).
    fn delete(&self, key: Value) -> Result<Value, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        let prev: Option<Any> = write(doc, move |txn| {
            let Some(m) = resolve::<MapRef, _>(txn, id) else {
                return Ok(None);
            };
            // Convert before removing (a removed shared ref would dangle).
            let prev = m.get(txn, &key).map(|v| out_to_any(txn, &v));
            m.remove(txn, &key);
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
        write(doc, move |txn| {
            if let Some(m) = resolve::<MapRef, _>(txn, id) {
                m.clear(txn);
            }
            Ok(())
        })
    }
}

/// Ensure a root map exists and return a live handle to it. Called by
/// `Y::Doc#get_map`.
pub fn root_map(doc: &Doc, name: String) -> Result<RbMap, Error> {
    let d = doc.clone();
    let id = nogvl(move || identity(&d.get_or_insert_map(name.as_str())))?;
    Ok(RbMap::new(doc.clone(), id))
}

pub fn define(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    let class = module.define_class("Map", ruby.class_object())?;
    class.define_method("[]", magnus::method!(RbMap::get, 1))?;
    class.define_method("get", magnus::method!(RbMap::get, 1))?;
    class.define_method("get_map", magnus::method!(RbMap::get_map, 1))?;
    class.define_method("get_array", magnus::method!(RbMap::get_array, 1))?;
    class.define_method("get_text", magnus::method!(RbMap::get_text, 1))?;
    class.define_method("[]=", magnus::method!(RbMap::set, 2))?;
    class.define_method("set", magnus::method!(RbMap::set, 2))?;
    class.define_method("native_set_text", magnus::method!(RbMap::set_text, 2))?;
    class.define_method("delete", magnus::method!(RbMap::delete, 1))?;
    class.define_method("clear", magnus::method!(RbMap::clear, 0))?;
    class.define_method("key?", magnus::method!(RbMap::has_key, 1))?;
    class.define_method("has_key?", magnus::method!(RbMap::has_key, 1))?;
    class.define_method("size", magnus::method!(RbMap::size, 0))?;
    class.define_method("length", magnus::method!(RbMap::size, 0))?;
    class.define_method("keys", magnus::method!(RbMap::keys, 0))?;
    class.define_method("to_h", magnus::method!(RbMap::to_h, 0))?;
    class.define_method("each", magnus::method!(RbMap::each, 0))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    //! What a handle's identity resolves to, then each method on a handle,
    //! called as Ruby calls it.
    use super::*;
    use crate::shared::test_support::{doc, hash, int, rb};
    use rb_sys_test_helpers::ruby_test;
    use yrs::{ArrayPrelim, MapPrelim, TextPrelim, Transact};

    #[test]
    fn a_root_map_resolves() {
        let doc = Doc::new();
        let id = identity(&doc.get_or_insert_map("state"));
        let txn = doc.transact();
        assert!(resolve::<MapRef, _>(&txn, &id).is_some());
    }

    #[test]
    fn a_nested_map_resolves_until_it_is_deleted() {
        let doc = Doc::new();
        let root = doc.get_or_insert_map("state");
        let mut txn = doc.transact_mut();
        let inner = root.insert(&mut txn, "user", MapPrelim::default());
        inner.insert(&mut txn, "name", "Ada");
        let id = identity(&inner);
        assert!(resolve::<MapRef, _>(&txn, &id).is_some());
        root.remove(&mut txn, "user");
        assert!(resolve::<MapRef, _>(&txn, &id).is_none());
    }

    fn state() -> RbMap {
        root_map(&doc(), "state".into()).unwrap()
    }

    #[ruby_test]
    fn set_returns_the_value_and_get_reads_it_back() {
        let map = state();
        assert_eq!(map.set(rb("n"), rb(1)).unwrap().inspect(), "1");
        assert_eq!(map.get(rb("n")).unwrap().inspect(), "1");
        assert_eq!(map.get(rb("missing")).unwrap().inspect(), "nil");
    }

    #[ruby_test]
    fn a_symbol_key_is_its_string() {
        let map = state();
        let ruby = Ruby::get().unwrap();
        map.set(ruby.to_symbol("n").as_value(), rb(1)).unwrap();
        assert!(map.has_key(rb("n")).unwrap());
        assert_eq!(map.keys().unwrap(), vec!["n".to_string()]);
    }

    #[ruby_test]
    fn size_keys_and_to_h_read_every_entry() {
        let map = state();
        map.set(rb("a"), rb(1)).unwrap();
        map.set(rb("b"), rb("two")).unwrap();
        assert_eq!(map.size().unwrap(), 2);
        let mut keys = map.keys().unwrap();
        keys.sort();
        assert_eq!(keys, vec!["a", "b"]);
        let mut entries = map.snapshot().unwrap();
        entries.sort_by(|x, y| x.0.cmp(&y.0));
        assert_eq!(
            entries,
            vec![("a".into(), int(1)), ("b".into(), Any::from("two"))]
        );
    }

    #[ruby_test]
    fn delete_returns_the_previous_value_or_nil() {
        let map = state();
        map.set(rb("n"), rb(1)).unwrap();
        assert_eq!(map.delete(rb("n")).unwrap().inspect(), "1");
        assert_eq!(map.delete(rb("n")).unwrap().inspect(), "nil");
        assert!(!map.has_key(rb("n")).unwrap());
    }

    #[ruby_test]
    fn clear_removes_every_entry() {
        let map = state();
        map.set(rb("a"), rb(1)).unwrap();
        map.set(rb("b"), rb(2)).unwrap();
        map.clear().unwrap();
        assert_eq!(map.size().unwrap(), 0);
    }

    #[ruby_test]
    fn a_hash_value_becomes_a_live_nested_map() {
        let map = state();
        map.set(rb("user"), hash(&[("name", rb("Ada"))]).as_value())
            .unwrap();
        assert!(matches!(map.child(rb("user")).unwrap(), Child::Map(_)));
        let user = map.get_map(rb("user")).unwrap().expect("a map at user");
        user.set(rb("age"), rb(36)).unwrap();
        let mut entries = user.snapshot().unwrap();
        entries.sort_by(|x, y| x.0.cmp(&y.0));
        assert_eq!(
            entries,
            vec![("age".into(), int(36)), ("name".into(), Any::from("Ada"))]
        );
    }

    #[ruby_test]
    fn get_map_get_text_and_get_array_narrow_by_type() {
        let map = state();
        map.set(rb("n"), rb(1)).unwrap();
        {
            let mut txn = map.doc.transact_mut();
            let m = resolve::<MapRef, _>(&txn, &map.id).unwrap();
            m.insert(&mut txn, "notes", TextPrelim::new("hi"));
            m.insert(&mut txn, "list", ArrayPrelim::default());
        }
        assert!(matches!(map.child(rb("missing")).unwrap(), Child::Other));
        assert!(map.get_map(rb("n")).unwrap().is_none());
        assert!(map.get_text(rb("notes")).unwrap().is_some());
        assert!(map.get_text(rb("list")).unwrap().is_none());
        assert!(map.get_array(rb("list")).unwrap().is_some());
        assert!(map.get_array(rb("notes")).unwrap().is_none());
    }

    #[ruby_test]
    fn a_handle_to_a_deleted_map_reads_empty_and_refuses_writes() {
        let map = state();
        map.set(rb("user"), hash(&[("name", rb("Ada"))]).as_value())
            .unwrap();
        let user = map.get_map(rb("user")).unwrap().unwrap();
        map.delete(rb("user")).unwrap();
        assert_eq!(user.size().unwrap(), 0);
        assert_eq!(user.get(rb("name")).unwrap().inspect(), "nil");
        let err = user.set(rb("name"), rb("Grace")).unwrap_err();
        assert!(err.to_string().contains("map no longer exists"), "{err}");
    }
}
