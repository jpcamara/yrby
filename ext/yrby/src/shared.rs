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
use yrs::branch::BranchPtr;
use yrs::types::text::YChange;
use yrs::{
    Any, Array, ArrayRef, In, Map, MapPrelim, MapRef, Out, ReadTxn, Text, TextRef, XmlTextRef,
};

/// The largest integer a double represents exactly (2^53).
const MAX_SAFE_INTEGER: u64 = 1 << 53;

/// One step of a handle's path: a key into a map, or an index into an array.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Seg {
    Key(String),
    Index(u32),
    /// The n-th `XmlText` embedded in an `XmlText`: how a rich-text block
    /// (a Lexical paragraph, say) is addressed inside its parent.
    Embed(u32),
}

/// Which root a path starts from. The root's type is fixed by the handle that
/// owns it (`Doc#get_map` starts at a map root, and so on).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Root {
    Map,
    Array,
    Text,
    XmlText,
}

/// A resolved branch. Callers narrow it to the type they need.
pub enum Branch {
    Map(MapRef),
    Array(ArrayRef),
    Text(TextRef),
    XmlText(XmlTextRef),
}

fn descend<T: ReadTxn>(txn: &T, branch: Branch, seg: &Seg) -> Option<Branch> {
    let out = match (branch, seg) {
        (Branch::Map(m), Seg::Key(k)) => m.get(txn, k),
        (Branch::Array(a), Seg::Index(i)) => a.get(txn, *i),
        (Branch::XmlText(x), Seg::Embed(n)) => embedded_xml_text(txn, &x, *n),
        // A key into an array or an index into a map is a path that no longer
        // describes the document.
        _ => None,
    }?;
    match out {
        Out::YMap(m) => Some(Branch::Map(m)),
        Out::YArray(a) => Some(Branch::Array(a)),
        Out::YText(t) => Some(Branch::Text(t)),
        Out::YXmlText(x) => Some(Branch::XmlText(x)),
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
        Root::XmlText => Branch::XmlText(root_xml_text(txn, root)?),
    };
    for seg in path {
        branch = descend(txn, branch, seg)?;
    }
    Some(branch)
}

/// The root `XmlText` named `root`. Editors like Lexical keep their document in
/// a root of this type. yrs has no root accessor for it, but a root's type is
/// local metadata: it is repaired on first lookup and never encoded, so we look
/// it up the way the reader does (as an XML fragment) and address the same
/// branch as an `XmlText`.
pub fn root_xml_text<T: ReadTxn>(txn: &T, root: &str) -> Option<XmlTextRef> {
    let fragment = txn.get_xml_fragment(root)?;
    let branch: &yrs::branch::Branch = fragment.as_ref();
    Some(XmlTextRef::from(BranchPtr::from(branch)))
}

/// The `n`-th `XmlText` embedded in `parent`, in document order.
pub fn embedded_xml_text<T: ReadTxn>(txn: &T, parent: &XmlTextRef, n: u32) -> Option<Out> {
    parent
        .diff(txn, YChange::identity)
        .into_iter()
        .filter(|d| matches!(d.insert, Out::YXmlText(_)))
        .nth(n as usize)
        .map(|d| d.insert)
}

/// The sequence index (the position `insert`/`remove_range` count in) of the
/// `n`-th `XmlText` embedded in `parent`: characters before it count one
/// each, embeds count one.
pub fn embedded_xml_text_index<T: ReadTxn>(txn: &T, parent: &XmlTextRef, n: u32) -> Option<u32> {
    let mut seen = 0u32;
    let mut index = 0u32;
    for d in parent.diff(txn, YChange::identity) {
        match &d.insert {
            Out::YXmlText(_) => {
                if seen == n {
                    return Some(index);
                }
                seen += 1;
                index += 1;
            }
            Out::Any(Any::String(s)) => index += s.encode_utf16().count() as u32,
            _ => index += 1,
        }
    }
    None
}

/// The strings in `block`, markers skipped, nested blocks joined by newlines.
pub fn block_text<T: ReadTxn>(txn: &T, block: &XmlTextRef) -> String {
    let mut out = String::new();
    for d in block.diff(txn, YChange::identity) {
        match &d.insert {
            Out::Any(Any::String(s)) => out.push_str(s),
            Out::YXmlText(child) => {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(&block_text(txn, child));
            }
            _ => {}
        }
    }
    out
}

/// How many `XmlText`s are embedded in `parent`.
pub fn embedded_xml_text_count<T: ReadTxn>(txn: &T, parent: &XmlTextRef) -> u32 {
    parent
        .diff(txn, YChange::identity)
        .iter()
        .filter(|d| matches!(d.insert, Out::YXmlText(_)))
        .count() as u32
}

pub fn resolve_xml_text<T: ReadTxn>(
    txn: &T,
    kind: Root,
    root: &str,
    path: &[Seg],
) -> Option<XmlTextRef> {
    match resolve(txn, kind, root, path)? {
        Branch::XmlText(x) => Some(x),
        _ => None,
    }
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
        InValue::Map(entries) => In::from(to_map_prelim(entries)),
    }
}

/// A nested shared map from Ruby pairs (what an editor's node marker is).
pub fn to_map_prelim(entries: Vec<(String, InValue)>) -> MapPrelim {
    entries.into_iter().map(|(k, cv)| (k, to_in(cv))).collect()
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
        // Yjs encodes ordinary integers as numbers, which JavaScript reads as
        // plain numbers. A BigInt would come back as a JS BigInt, which breaks
        // JSON.stringify and the bitwise math editors do on flags like
        // `__format`. Only an integer a double cannot hold stays a BigInt.
        let i = i.to_i64()?;
        return Ok(InValue::Any(if i.unsigned_abs() <= MAX_SAFE_INTEGER {
            Any::Number(i as f64)
        } else {
            Any::BigInt(i)
        }));
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
        // A whole number reads back as an Integer, as JSON.parse would give.
        Any::Number(n) if n.fract() == 0.0 && n.abs() <= MAX_SAFE_INTEGER as f64 => {
            (*n as i64).into_value_with(ruby)
        }
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
