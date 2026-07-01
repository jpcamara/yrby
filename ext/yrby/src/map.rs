//! Live `Y::Map` handles over a yrs `Map`, exposing read + write of actual
//! shared data (not just opaque CRDT sync).
//!
//! Thread safety mirrors `Y::Doc` exactly: every operation opens its own
//! transaction inside `nogvl` (GVL released) and holds no lock across the GVL
//! boundary. Ruby values are read/built only with the GVL held (before/after the
//! `nogvl` block); the closure works purely on `Send` data.
//!
//! A map is addressed by its root name plus a path of keys, and re-resolved per
//! operation — so we never cache a raw yrs branch pointer that could dangle when
//! the tree is mutated (possibly on another thread). If the path no longer points
//! at a map, reads return empty and writes are a no-op error.

use magnus::{
    prelude::*, r_hash::ForEach, Error, Float, Integer, IntoValue, RArray, RHash, RString, Ruby,
    Value,
};
use yrs::{Any, Doc, In, Map, MapPrelim, MapRef, Out, ReadTxn, Transact};

use crate::read::out_to_any;
use crate::{nogvl, yrb_error};

/// A live handle to a yrs `Map` inside a `Doc`. `Send + Sync` (all fields are),
/// so it satisfies the same thread-safety assertion as `Y::Doc`.
#[magnus::wrap(class = "Y::Map", free_immediately, size)]
pub struct RbMap {
    doc: Doc,
    root: String,
    path: Vec<String>,
}

/// Resolve the `MapRef` for `(root, path)` within a transaction, or `None` if the
/// path no longer points at a map. Never caches the ref beyond the transaction.
fn resolve<T: ReadTxn>(txn: &T, root: &str, path: &[String]) -> Option<MapRef> {
    let mut m = txn.get_map(root)?;
    for key in path {
        match m.get(txn, key) {
            Some(Out::YMap(child)) => m = child,
            _ => return None,
        }
    }
    Some(m)
}

/// A `Send` intermediate: Ruby is read into this with the GVL held, then it is
/// turned into yrs input inside `nogvl` (no Ruby calls there).
enum InValue {
    Any(Any),
    Map(Vec<(String, InValue)>),
}

fn to_in(v: InValue) -> In {
    match v {
        InValue::Any(a) => In::Any(a),
        InValue::Map(entries) => {
            let m: MapPrelim = entries.into_iter().map(|(k, cv)| (k, to_in(cv))).collect();
            In::from(m)
        }
    }
}

/// Flatten an `InValue` to `Any` (nested maps become `Any::Map` snapshots). Used
/// for array elements, which we store as plain `Any` values in this first cut.
fn invalue_to_any(v: InValue) -> Any {
    match v {
        InValue::Any(a) => a,
        InValue::Map(entries) => {
            let mut hm = std::collections::HashMap::new();
            for (k, cv) in entries {
                hm.insert(k, invalue_to_any(cv));
            }
            Any::Map(std::sync::Arc::new(hm))
        }
    }
}

fn key_to_string(v: Value) -> Result<String, Error> {
    if let Some(s) = RString::from_value(v) {
        return s.to_string();
    }
    // Symbols and everything else: use to_s.
    let s: String = v.funcall("to_s", ())?;
    Ok(s)
}

/// Read a Ruby value into an `InValue`. GVL held. Ruby `Hash` → live nested map;
/// `Array` → embedded array of primitives; primitives → the matching `Any`.
fn ruby_to_invalue(ruby: &Ruby, v: Value) -> Result<InValue, Error> {
    if v.is_nil() {
        return Ok(InValue::Any(Any::Null));
    }
    if v.equal(ruby.qtrue())? {
        return Ok(InValue::Any(Any::Bool(true)));
    }
    if v.equal(ruby.qfalse())? {
        return Ok(InValue::Any(Any::Bool(false)));
    }
    if let Some(h) = RHash::from_value(v) {
        let mut entries: Vec<(String, InValue)> = Vec::new();
        h.foreach(|k: Value, val: Value| {
            entries.push((key_to_string(k)?, ruby_to_invalue(ruby, val)?));
            Ok(ForEach::Continue)
        })?;
        return Ok(InValue::Map(entries));
    }
    if let Some(a) = RArray::from_value(v) {
        let mut items: Vec<Any> = Vec::with_capacity(a.len());
        for item in a.into_iter() {
            items.push(invalue_to_any(ruby_to_invalue(ruby, item)?));
        }
        return Ok(InValue::Any(Any::Array(items.into())));
    }
    if let Some(i) = Integer::from_value(v) {
        return Ok(InValue::Any(Any::BigInt(i.to_i64()?)));
    }
    if let Some(f) = Float::from_value(v) {
        return Ok(InValue::Any(Any::Number(f.to_f64())));
    }
    if let Some(s) = RString::from_value(v) {
        return Ok(InValue::Any(Any::String(s.to_string()?.into())));
    }
    // Fallback: stringify (covers Symbol and other to_s-able objects).
    Ok(InValue::Any(Any::String(key_to_string(v)?.into())))
}

/// Build a Ruby value from an `Any`. GVL held.
fn any_to_ruby(ruby: &Ruby, a: &Any) -> Value {
    match a {
        Any::Null | Any::Undefined => ruby.qnil().as_value(),
        Any::Bool(b) => (*b).into_value_with(ruby),
        Any::Number(n) => (*n).into_value_with(ruby),
        Any::BigInt(i) => (*i).into_value_with(ruby),
        Any::String(s) => s.as_ref().into_value_with(ruby),
        Any::Buffer(buf) => ruby.str_from_slice(buf).as_value(),
        Any::Array(items) => ruby
            .ary_from_iter(items.iter().map(|it| any_to_ruby(ruby, it)))
            .as_value(),
        Any::Map(m) => {
            let h = ruby.hash_new();
            for (k, v) in m.iter() {
                let _ = h.aset(k.as_str(), any_to_ruby(ruby, v));
            }
            h.as_value()
        }
    }
}

impl RbMap {
    pub fn root(doc: Doc, root: String) -> Self {
        RbMap {
            doc,
            root,
            path: Vec::new(),
        }
    }

    fn child(&self, key: String) -> Self {
        let mut path = self.path.clone();
        path.push(key);
        RbMap {
            doc: self.doc.clone(),
            root: self.root.clone(),
            path,
        }
    }

    // --- reads ---

    /// `map[key]` — a snapshot Ruby value (primitives; nested map/array become a
    /// deep `Hash`/`Array`). Use `get_map` for a live nested handle.
    fn get(&self, key: Value) -> Result<Value, Error> {
        let key = key_to_string(key)?;
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        let got: Option<Any> = nogvl(move || {
            let txn = doc.transact();
            let m = resolve(&txn, root, path)?;
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
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        let probe = key.clone();
        let is_map = nogvl(move || {
            let txn = doc.transact();
            resolve(&txn, root, path)
                .map(|m| matches!(m.get(&txn, &probe), Some(Out::YMap(_))))
                .unwrap_or(false)
        });
        Ok(is_map.then(|| self.child(key)))
    }

    fn has_key(&self, key: Value) -> Result<bool, Error> {
        let key = key_to_string(key)?;
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        Ok(nogvl(move || {
            let txn = doc.transact();
            resolve(&txn, root, path)
                .map(|m| m.contains_key(&txn, &key))
                .unwrap_or(false)
        }))
    }

    fn size(&self) -> usize {
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            resolve(&txn, root, path)
                .map(|m| m.len(&txn) as usize)
                .unwrap_or(0)
        })
    }

    fn keys(&self) -> Vec<String> {
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            match resolve(&txn, root, path) {
                Some(m) => m.keys(&txn).map(|k| k.to_string()).collect(),
                None => Vec::new(),
            }
        })
    }

    fn snapshot(&self) -> Vec<(String, Any)> {
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || {
            let txn = doc.transact();
            match resolve(&txn, root, path) {
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

    /// `each { |key, value| }` — yields a snapshot of each entry (read under
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

    /// `map[key] = value` — store a value. Ruby `Hash` creates a live nested map;
    /// `Array` an embedded array; primitives their `Any` counterpart. Returns the
    /// value assigned (so `map[k] = v` yields `v`, as Ruby expects).
    fn set(&self, key: Value, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().unwrap();
        let key = key_to_string(key)?;
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || -> Result<(), String> {
            let mut txn = doc.transact_mut();
            let m = resolve(&txn, root, path).ok_or_else(|| "map no longer exists".to_string())?;
            m.insert(&mut txn, key, to_in(iv));
            Ok(())
        })
        .map_err(yrb_error)?;
        Ok(value)
    }

    /// Remove `key`, returning its previous snapshot value (or `nil`).
    fn delete(&self, key: Value) -> Result<Value, Error> {
        let key = key_to_string(key)?;
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        let prev: Option<Any> = nogvl(move || {
            let mut txn = doc.transact_mut();
            let m = resolve(&txn, root, path)?;
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
        let (doc, root, path) = (&self.doc, &self.root, &self.path);
        nogvl(move || {
            let mut txn = doc.transact_mut();
            if let Some(m) = resolve(&txn, root, path) {
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
    //! Rust-side tests for the `Send` helpers that don't touch Ruby (`resolve`,
    //! `to_in`, `invalue_to_any`). The Ruby↔value conversions and the method
    //! surface are covered by `test/map_test.rb`.
    use super::*;

    #[test]
    fn resolve_returns_root_map() {
        let doc = Doc::new();
        doc.get_or_insert_map("state");
        let txn = doc.transact();
        assert!(resolve(&txn, "state", &[]).is_some());
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
        let inner = resolve(&txn, "state", &["user".to_string()]).unwrap();
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
        assert!(resolve(&txn, "state", &["scalar".to_string()]).is_none());
        assert!(resolve(&txn, "state", &["missing".to_string()]).is_none());
    }

    #[test]
    fn to_in_builds_live_nested_map() {
        // A Map InValue becomes a real nested Y.Map (not a flattened Any), so a
        // handle to it would be live.
        let iv = InValue::Map(vec![
            ("name".to_string(), InValue::Any(Any::from("Ada"))),
            (
                "addr".to_string(),
                InValue::Map(vec![("city".to_string(), InValue::Any(Any::from("NYC")))]),
            ),
        ]);
        let doc = Doc::new();
        let root = doc.get_or_insert_map("state");
        {
            let mut txn = doc.transact_mut();
            root.insert(&mut txn, "user", to_in(iv));
        }
        let txn = doc.transact();
        let user = match root.get(&txn, "user") {
            Some(Out::YMap(m)) => m,
            other => panic!("expected nested YMap, got {other:?}"),
        };
        let addr = match user.get(&txn, "addr") {
            Some(Out::YMap(m)) => m,
            other => panic!("expected nested addr YMap, got {other:?}"),
        };
        assert!(matches!(
            addr.get(&txn, "city"),
            Some(Out::Any(Any::String(_)))
        ));
    }

    #[test]
    fn invalue_to_any_flattens_nested_map() {
        let iv = InValue::Map(vec![("k".to_string(), InValue::Any(Any::from("v")))]);
        match invalue_to_any(iv) {
            Any::Map(m) => {
                assert_eq!(m.len(), 1);
                assert!(matches!(m.get("k"), Some(Any::String(s)) if s.as_ref() == "v"));
            }
            other => panic!("expected Any::Map, got {other:?}"),
        }
        // A plain Any passes straight through.
        assert!(matches!(
            invalue_to_any(InValue::Any(Any::BigInt(7))),
            Any::BigInt(7)
        ));
    }
}
