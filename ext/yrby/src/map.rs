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

use magnus::{prelude::*, Error, Ruby, Value};
use yrs::branch::BranchID;
use yrs::{Any, Doc, Map, MapRef, Out, Transact};

use crate::array::RbArray;
use crate::nogvl;
use crate::read::out_to_any;
use crate::shared::{
    any_to_ruby, guarded, identity, key_to_string, resolve, ruby_to_invalue, to_in, ORIGIN,
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
    fn child(&self, key: Value) -> Result<Option<Out>, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        Ok(nogvl(move || {
            let txn = doc.transact();
            resolve::<MapRef, _>(&txn, id)?.get(&txn, &key)
        }))
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
        });
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
            Some(Out::YMap(m)) => Some(RbMap::new(self.doc.clone(), identity(&m))),
            _ => None,
        })
    }

    /// A live `Y::Array` for an array stored at `key`.
    fn get_array(&self, key: Value) -> Result<Option<RbArray>, Error> {
        Ok(match self.child(key)? {
            Some(Out::YArray(a)) => Some(RbArray::new(self.doc.clone(), identity(&a))),
            _ => None,
        })
    }

    /// A live `Y::Text` for text stored at `key`.
    fn get_text(&self, key: Value) -> Result<Option<RbText>, Error> {
        Ok(match self.child(key)? {
            Some(Out::YText(t)) => Some(RbText::new(self.doc.clone(), identity(&t))),
            _ => None,
        })
    }

    fn has_key(&self, key: Value) -> Result<bool, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        Ok(nogvl(move || {
            let txn = doc.transact();
            resolve::<MapRef, _>(&txn, id)
                .map(|m| m.contains_key(&txn, &key))
                .unwrap_or(false)
        }))
    }

    fn size(&self) -> usize {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<MapRef, _>(&txn, id)
                .map(|m| m.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn keys(&self) -> Vec<String> {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            match resolve::<MapRef, _>(&txn, id) {
                Some(m) => m.keys(&txn).map(|k| k.to_string()).collect(),
                None => Vec::new(),
            }
        })
    }

    fn snapshot(&self) -> Vec<(String, Any)> {
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

    fn to_h(&self) -> Value {
        let ruby = Ruby::get().unwrap();
        let h = ruby.hash_new();
        for (k, v) in &self.snapshot() {
            let _ = h.aset(k.as_str(), any_to_ruby(&ruby, v));
        }
        h.as_value()
    }

    /// `each { |key, value| }`: yields a snapshot of each entry (read under
    /// `nogvl`, yielded with the GVL held so the block can call back into Ruby).
    fn each(&self) -> Result<(), Error> {
        let ruby = Ruby::get().unwrap();
        let block = ruby.block_proc()?;
        for (k, v) in &self.snapshot() {
            let _: Value = block.call((k.as_str(), any_to_ruby(&ruby, v)))?;
        }
        Ok(())
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
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let m = resolve::<MapRef, _>(&txn, id).ok_or("map no longer exists")?;
            m.insert(&mut txn, key, to_in(iv));
            Ok(())
        })?;
        Ok(value)
    }

    /// Remove `key`, returning its previous snapshot value (or `nil`).
    fn delete(&self, key: Value) -> Result<Value, Error> {
        let key = key_to_string(key)?;
        let (doc, id) = (&self.doc, &self.id);
        let prev: Option<Any> = guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let Some(m) = resolve::<MapRef, _>(&txn, id) else {
                return Ok(None);
            };
            // Convert before removing (a removed shared ref would dangle).
            let prev = m.get(&txn, &key).map(|v| out_to_any(&txn, &v));
            m.remove(&mut txn, &key);
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
            if let Some(m) = resolve::<MapRef, _>(&txn, id) {
                m.clear(&mut txn);
            }
            Ok(())
        })
    }
}

/// Ensure a root map exists and return a live handle to it. Called by
/// `Y::Doc#get_map`.
pub fn root_map(doc: &Doc, name: String) -> RbMap {
    let d = doc.clone();
    let id = nogvl(move || identity(&d.get_or_insert_map(name.as_str())));
    RbMap::new(doc.clone(), id)
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
    //! What a handle's identity resolves to: a root map, a nested map, and
    //! nothing once the nested map has been deleted.
    use super::*;
    use yrs::MapPrelim;

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
}
