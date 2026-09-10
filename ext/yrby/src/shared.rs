//! Machinery every live handle shares: how a handle addresses a branch inside a
//! document, and how Ruby values cross into yrs and back.
//!
//! A handle never caches a yrs branch pointer. It stores a root name and a path,
//! and re-resolves per operation, so a handle cannot dangle when the tree is
//! mutated (possibly on another thread). A path segment is either a map key or
//! an array index, which is what lets a handle reach a map nested inside an
//! array: the shape an agent's worklist actually has.
//!
//! Ruby values are read and built only with the GVL held. Everything that
//! crosses into a `nogvl` closure is `Send` data with no Ruby in it.

use magnus::{
    prelude::*, r_hash::ForEach, Error, Float, Integer, IntoValue, RArray, RHash, RString, Ruby,
    Value,
};
use yrs::{Any, Array, ArrayRef, In, Map, MapPrelim, MapRef, Out, ReadTxn, TextRef};

/// One step of a handle's path: a key into a map, or an index into an array.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Seg {
    Key(String),
    Index(u32),
}

/// Which root a path starts from. The root's type is fixed by the handle that
/// owns it (`Doc#get_map` starts at a map root, and so on).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Root {
    Map,
    Array,
    Text,
}

/// A resolved branch. Callers narrow it to the type they need.
pub enum Branch {
    Map(MapRef),
    Array(ArrayRef),
    Text(TextRef),
}

fn descend<T: ReadTxn>(txn: &T, branch: Branch, seg: &Seg) -> Option<Branch> {
    let out = match (branch, seg) {
        (Branch::Map(m), Seg::Key(k)) => m.get(txn, k),
        (Branch::Array(a), Seg::Index(i)) => a.get(txn, *i),
        // A key into an array or an index into a map is a path that no longer
        // describes the document.
        _ => None,
    }?;
    match out {
        Out::YMap(m) => Some(Branch::Map(m)),
        Out::YArray(a) => Some(Branch::Array(a)),
        Out::YText(t) => Some(Branch::Text(t)),
        _ => None,
    }
}

/// Walk `(root, path)` to a branch, or `None` if the path no longer points at
/// one. Never caches beyond the transaction.
pub fn resolve<T: ReadTxn>(txn: &T, kind: Root, root: &str, path: &[Seg]) -> Option<Branch> {
    let mut branch = match kind {
        Root::Map => Branch::Map(txn.get_map(root)?),
        Root::Array => Branch::Array(txn.get_array(root)?),
        Root::Text => Branch::Text(txn.get_text(root)?),
    };
    for seg in path {
        branch = descend(txn, branch, seg)?;
    }
    Some(branch)
}

pub fn resolve_map<T: ReadTxn>(txn: &T, kind: Root, root: &str, path: &[Seg]) -> Option<MapRef> {
    match resolve(txn, kind, root, path)? {
        Branch::Map(m) => Some(m),
        _ => None,
    }
}

pub fn resolve_array<T: ReadTxn>(
    txn: &T,
    kind: Root,
    root: &str,
    path: &[Seg],
) -> Option<ArrayRef> {
    match resolve(txn, kind, root, path)? {
        Branch::Array(a) => Some(a),
        _ => None,
    }
}

pub fn resolve_text<T: ReadTxn>(txn: &T, kind: Root, root: &str, path: &[Seg]) -> Option<TextRef> {
    match resolve(txn, kind, root, path)? {
        Branch::Text(t) => Some(t),
        _ => None,
    }
}

/// A `Send` intermediate: Ruby is read into this with the GVL held, then turned
/// into yrs input inside `nogvl` (no Ruby calls there).
pub enum InValue {
    Any(Any),
    Map(Vec<(String, InValue)>),
}

pub fn to_in(v: InValue) -> In {
    match v {
        InValue::Any(a) => In::Any(a),
        InValue::Map(entries) => {
            let m: MapPrelim = entries.into_iter().map(|(k, cv)| (k, to_in(cv))).collect();
            In::from(m)
        }
    }
}

/// Flatten an `InValue` to `Any` (nested maps become `Any::Map` snapshots).
pub fn invalue_to_any(v: InValue) -> Any {
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

pub fn key_to_string(v: Value) -> Result<String, Error> {
    if let Some(s) = RString::from_value(v) {
        return s.to_string();
    }
    // Symbols and everything else: use to_s.
    let s: String = v.funcall("to_s", ())?;
    Ok(s)
}

/// Read a Ruby value into an `InValue`. GVL held. Ruby `Hash` becomes a live
/// nested map; `Array` an embedded array of primitives; primitives their `Any`.
pub fn ruby_to_invalue(ruby: &Ruby, v: Value) -> Result<InValue, Error> {
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
pub fn any_to_ruby(ruby: &Ruby, a: &Any) -> Value {
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
