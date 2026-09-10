//! Live `Y::Map` handles over a yrs `Map`, exposing read + write of actual
//! shared data (not just opaque CRDT sync).
//!
//! Thread safety mirrors `Y::Doc` exactly: every operation opens its own
//! transaction inside `nogvl` (GVL released) and holds no lock across the GVL
//! boundary. Ruby values are read/built only with the GVL held (before/after the
//! `nogvl` block); the closure works purely on `Send` data.
//!
//! A map is addressed by its root name plus a path, and re-resolved per
//! operation, so we never cache a raw yrs branch pointer that could dangle when
//! the tree is mutated (possibly on another thread). If the path no longer points
//! at a map, reads return empty and writes are a no-op error. The path machinery
//! lives in `shared`, which every live handle uses.

use magnus::{prelude::*, Error, Ruby, Value};
use yrs::{Any, Doc, Map, Out, Transact};

use crate::array::RbArray;
use crate::read::out_to_any;
use crate::shared::{any_to_ruby, key_to_string, resolve_map, ruby_to_invalue, to_in, Root, Seg};
use crate::text::RbText;
use crate::{nogvl, yrb_error};

/// A live handle to a yrs `Map` inside a `Doc`. `Send + Sync` (all fields are),
/// so it satisfies the same thread-safety assertion as `Y::Doc`.
#[magnus::wrap(class = "Y::Map", free_immediately, size)]
pub struct RbMap {
    doc: Doc,
    kind: Root,
    root: String,
    path: Vec<Seg>,
}

impl RbMap {
    pub fn root(doc: Doc, root: String) -> Self {
        RbMap {
            doc,
            kind: Root::Map,
            root,
            path: Vec::new(),
        }
    }

    /// A handle to a map living somewhere else in the tree, addressed from that
    /// branch's own root. This is how `Y::Array#get_map` hands back an element.
    pub fn at(doc: Doc, kind: Root, root: String, path: Vec<Seg>) -> Self {
        RbMap {
            doc,
            kind,
            root,
            path,
        }
    }

    fn child(&self, key: String) -> Self {
        let mut path = self.path.clone();
        path.push(Seg::Key(key));
        RbMap {
            doc: self.doc.clone(),
            kind: self.kind,
            root: self.root.clone(),
            path,
        }
    }

    // --- reads ---

    /// `map[key]`: a snapshot Ruby value (primitives; nested map/array become a
    /// deep `Hash`/`Array`). Use `get_map` for a live nested handle.
    fn get(&self, key: Value) -> Result<Value, Error> {
        let key = key_to_string(key)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let got: Option<Any> = nogvl(move || {
            let txn = doc.transact();
            let m = resolve_map(&txn, kind, root, path)?;
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
        let key = key_to_string(key)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let probe = key.clone();
        let is_map = nogvl(move || {
            let txn = doc.transact();
            resolve_map(&txn, kind, root, path)
                .map(|m| matches!(m.get(&txn, &probe), Some(Out::YMap(_))))
                .unwrap_or(false)
        });
        Ok(is_map.then(|| self.child(key)))
    }

    /// A live `Y::Array` for an array stored at `key`.
    fn get_array(&self, key: Value) -> Result<Option<RbArray>, Error> {
        let key = key_to_string(key)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let probe = key.clone();
        let is_array = nogvl(move || {
            let txn = doc.transact();
            resolve_map(&txn, kind, root, path)
                .map(|m| matches!(m.get(&txn, &probe), Some(Out::YArray(_))))
                .unwrap_or(false)
        });
        Ok(is_array.then(|| {
            let mut path = self.path.clone();
            path.push(Seg::Key(key));
            RbArray::at(self.doc.clone(), self.kind, self.root.clone(), path)
        }))
    }

    /// A live `Y::Text` for text stored at `key`.
    fn get_text(&self, key: Value) -> Result<Option<RbText>, Error> {
        let key = key_to_string(key)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let probe = key.clone();
        let is_text = nogvl(move || {
            let txn = doc.transact();
            resolve_map(&txn, kind, root, path)
                .map(|m| matches!(m.get(&txn, &probe), Some(Out::YText(_))))
                .unwrap_or(false)
        });
        Ok(is_text.then(|| {
            let mut path = self.path.clone();
            path.push(Seg::Key(key));
            RbText::at(self.doc.clone(), self.kind, self.root.clone(), path)
        }))
    }

    fn has_key(&self, key: Value) -> Result<bool, Error> {
        let key = key_to_string(key)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        Ok(nogvl(move || {
            let txn = doc.transact();
            resolve_map(&txn, kind, root, path)
                .map(|m| m.contains_key(&txn, &key))
                .unwrap_or(false)
        }))
    }

    fn size(&self) -> usize {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve_map(&txn, kind, root, path)
                .map(|m| m.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn keys(&self) -> Vec<String> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            match resolve_map(&txn, kind, root, path) {
                Some(m) => m.keys(&txn).map(|k| k.to_string()).collect(),
                None => Vec::new(),
            }
        })
    }

    fn snapshot(&self) -> Vec<(String, Any)> {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            match resolve_map(&txn, kind, root, path) {
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
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let m = resolve_map(&txn, kind, root, path)
                .ok_or_else(|| "map no longer exists".to_string())?;
            m.insert(&mut txn, key, to_in(iv));
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(value)
    }

    /// Remove `key`, returning its previous snapshot value (or `nil`).
    fn delete(&self, key: Value) -> Result<Value, Error> {
        let key = key_to_string(key)?;
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        let prev: Option<Any> = nogvl(move || {
            let mut txn = doc.transact_mut();
            let m = resolve_map(&txn, kind, root, path)?;
            // Convert before removing (a removed shared ref would dangle).
            let prev = m.get(&txn, &key).map(|v| out_to_any(&txn, &v));
            m.remove(&mut txn, &key);
            prev
        });
        let ruby = Ruby::get().unwrap();
        Ok(match prev {
            Some(a) => any_to_ruby(&ruby, &a),
            None => ruby.qnil().as_value(),
        })
    }

    fn clear(&self) {
        let (doc, kind, root, path) = (&self.doc, self.kind, &self.root, &self.path);
        nogvl(move || {
            let mut txn = doc.transact_mut();
            if let Some(m) = resolve_map(&txn, kind, root, path) {
                m.clear(&mut txn);
            }
        });
    }
}

/// Ensure a root map exists and return a live handle to it. Called by
/// `Y::Doc#get_map`.
pub fn root_map(doc: &Doc, name: String) -> RbMap {
    let d = doc.clone();
    let root = name.clone();
    nogvl(move || {
        d.get_or_insert_map(root.as_str());
    });
    RbMap::root(doc.clone(), name)
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
    //! The path walk and the Ruby-free conversions moved to `shared`, which
    //! tests them directly. What is left here is the map-shaped resolution:
    //! that a map root resolves, that a key path follows nested maps, and that
    //! a path landing on something that is not a map resolves to nothing.
    use super::*;
    use crate::shared::resolve_map;
    use yrs::MapPrelim;

    #[test]
    fn resolve_returns_root_map() {
        let doc = Doc::new();
        doc.get_or_insert_map("state");
        let txn = doc.transact();
        assert!(resolve_map(&txn, Root::Map, "state", &[]).is_some());
    }

    #[test]
    fn resolve_follows_nested_path() {
        let doc = Doc::new();
        let root = doc.get_or_insert_map("state");
        {
            let mut txn = doc.transact_mut();
            let inner = root.insert(&mut txn, "user", MapPrelim::default());
            inner.insert(&mut txn, "name", "Ada");
        }
        let txn = doc.transact();
        let inner = resolve_map(&txn, Root::Map, "state", &[Seg::Key("user".to_string())]).unwrap();
        assert!(matches!(
            inner.get(&txn, "name"),
            Some(Out::Any(Any::String(_)))
        ));
    }

    #[test]
    fn resolve_none_when_path_is_not_a_map() {
        let doc = Doc::new();
        let root = doc.get_or_insert_map("state");
        {
            let mut txn = doc.transact_mut();
            root.insert(&mut txn, "scalar", 5_i64);
        }
        let txn = doc.transact();
        assert!(resolve_map(&txn, Root::Map, "state", &[Seg::Key("scalar".into())]).is_none());
        assert!(resolve_map(&txn, Root::Map, "state", &[Seg::Key("missing".into())]).is_none());
    }
}
