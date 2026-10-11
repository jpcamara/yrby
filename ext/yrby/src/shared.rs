//! Machinery every live handle shares: how a handle finds its branch, how
//! Ruby indexes map onto yrs's, and how Ruby values cross into yrs and back.
//!
//! A handle holds the identity of its branch: a root's name, or the ID of
//! the item that holds a nested type. It never caches a branch pointer, and
//! it resolves the identity in every operation's transaction. Identity, not
//! position: a block someone inserts above an agent's paragraph does not move
//! the agent's handle onto it, and a handle to a deleted branch resolves to
//! nothing instead of to whatever took its place.
//!
//! Indexes are Ruby characters. Documents count in UTF-16 units, as Yjs does,
//! and every index crosses through `to_units`/`to_chars`, so an index never
//! lands inside a character and `String#index` results can be used as is.
//!
//! Ruby values are read and built only with the GVL held. Everything that
//! crosses into a `nogvl` closure is `Send` data with no Ruby in it.

use std::panic::{catch_unwind, AssertUnwindSafe};

use magnus::{
    prelude::*, r_hash::ForEach, Error, Float, Integer, IntoValue, RArray, RHash, RString, Ruby,
    Value,
};
use yrs::branch::{BranchID, BranchPtr};
use yrs::types::text::YChange;
use yrs::{
    Any, Hook, In, IndexScope, MapPrelim, Out, ReadTxn, SharedRef, StickyIndex, Text, XmlTextRef,
};

use crate::{nogvl, yrb_error};

/// The origin of every transaction a handle opens. `Doc#diff` records only
/// these, so an update applied from elsewhere while it runs stays out.
pub const ORIGIN: &str = "yrby";

/// The largest integer a double represents exactly (2^53).
const MAX_SAFE_INTEGER: u64 = 1 << 53;

/// The branch `id` names, if it exists and has not been deleted.
pub fn resolve<S: SharedRef, T: ReadTxn>(txn: &T, id: &BranchID) -> Option<S> {
    Hook::<S>::from(id.clone()).get(txn)
}

/// The identity a handle keeps for `shared`.
pub fn identity<S: SharedRef>(shared: &S) -> BranchID {
    shared.hook().into()
}

/// Run `f` without the GVL. Its error, or a panic inside yrs, becomes a
/// `Y::Error` instead of taking the process down.
pub fn guarded<F, R>(f: F) -> Result<R, Error>
where
    F: FnOnce() -> Result<R, String> + Send,
    R: Send,
{
    nogvl(move || match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(panic) => Err(panic
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_else(|| "the document operation failed".to_string())),
    })
    .map_err(yrb_error)
}

// --- indexes ---

/// What `insert(index, ...)` means in a sequence of `len`, as in Ruby: a
/// negative index counts from the end, so -1 is the end itself. Clamped.
pub fn insert_index(index: i64, len: u32) -> u32 {
    let len = len as i64;
    let i = if index < 0 { len + index + 1 } else { index };
    i.clamp(0, len) as u32
}

/// The element `index` names in a sequence of `len`, as Ruby's `[]` reads
/// it: a negative index counts from the end, and an index outside is `None`.
pub fn element_index(index: i64, len: u32) -> Option<u32> {
    let len = len as i64;
    let i = if index < 0 { len + index } else { index };
    (0..len).contains(&i).then_some(i as u32)
}

/// The span `delete(index, length)` removes, as `String#slice!` reads it, in
/// characters: `None` when `index` is outside the text.
pub fn delete_span(index: i64, length: i64, len: u32) -> Option<(u32, u32)> {
    let len = len as i64;
    let start = if index < 0 { len + index } else { index };
    if start < 0 || start > len {
        return None;
    }
    let count = length.clamp(0, len - start);
    Some((start as u32, (start + count) as u32))
}

/// A sequence's contents in order: strings, and embeds (a text node's
/// marker, a nested block), each of which counts as one character.
fn pieces<T: ReadTxn, S: Text>(txn: &T, seq: &S) -> Vec<Out> {
    seq.diff(txn, YChange::identity)
        .into_iter()
        .map(|d| d.insert)
        .collect()
}

/// How many characters `seq` holds, counting each embed as one.
pub fn char_len<T: ReadTxn, S: Text>(txn: &T, seq: &S) -> u32 {
    pieces(txn, seq)
        .iter()
        .map(|piece| match piece {
            Out::Any(Any::String(s)) => s.chars().count() as u32,
            _ => 1,
        })
        .sum()
}

/// The document index (UTF-16 units) of character `chars` in `seq`.
pub fn to_units<T: ReadTxn, S: Text>(txn: &T, seq: &S, chars: u32) -> u32 {
    let mut left = chars;
    let mut units = 0;
    for piece in pieces(txn, seq) {
        if left == 0 {
            break;
        }
        match piece {
            Out::Any(Any::String(s)) => {
                for c in s.chars() {
                    if left == 0 {
                        break;
                    }
                    units += c.len_utf16() as u32;
                    left -= 1;
                }
            }
            _ => {
                units += 1;
                left -= 1;
            }
        }
    }
    units
}

/// The character index of document index `units` in `seq`.
pub fn to_chars<T: ReadTxn, S: Text>(txn: &T, seq: &S, units: u32) -> u32 {
    let mut left = units;
    let mut chars = 0;
    for piece in pieces(txn, seq) {
        if left == 0 {
            break;
        }
        match piece {
            Out::Any(Any::String(s)) => {
                for c in s.chars() {
                    if left == 0 {
                        break;
                    }
                    left = left.saturating_sub(c.len_utf16() as u32);
                    chars += 1;
                }
            }
            _ => {
                left -= 1;
                chars += 1;
            }
        }
    }
    chars
}

// --- blocks ---

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

/// The `XmlText`s embedded in `parent`, in order.
pub fn embedded_xml_texts<T: ReadTxn>(txn: &T, parent: &XmlTextRef) -> Vec<XmlTextRef> {
    pieces(txn, parent)
        .into_iter()
        .filter_map(|piece| match piece {
            Out::YXmlText(x) => Some(x),
            _ => None,
        })
        .collect()
}

/// The document index of the `n`-th `XmlText` embedded in `parent`.
pub fn embedded_xml_text_index<T: ReadTxn>(txn: &T, parent: &XmlTextRef, n: u32) -> Option<u32> {
    let mut seen = 0u32;
    let mut index = 0u32;
    for piece in pieces(txn, parent) {
        match &piece {
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

/// Whether the last thing in `block` is an embedded `XmlText` (a link, say).
pub fn ends_with_xml_text<T: ReadTxn>(txn: &T, block: &XmlTextRef) -> bool {
    matches!(pieces(txn, block).last(), Some(Out::YXmlText(_)))
}

/// The strings in `block`, markers skipped. Inline children (a link) join the
/// line and nested blocks (a list item) start a new one.
pub fn block_text<T: ReadTxn>(txn: &T, block: &XmlTextRef) -> String {
    let mut out = String::new();
    for piece in pieces(txn, block) {
        match &piece {
            Out::Any(Any::String(s)) => out.push_str(s),
            Out::YXmlText(child) => {
                let inline =
                    crate::read::is_inline_lexical_type(&crate::read::lexical_type(txn, child));
                if !inline && !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(&block_text(txn, child));
            }
            _ => {}
        }
    }
    out
}

// --- positions ---

/// A relative position with no Ruby in it: inside a sequence it names the
/// item to the right (or left); at the end of a nested type it names the
/// type; at a root it names the root.
pub struct Position {
    scope: IndexScope,
    assoc: i32,
}

impl Position {
    pub fn new(sticky: StickyIndex) -> Self {
        Position {
            assoc: sticky.assoc as i32,
            scope: sticky.scope().clone(),
        }
    }

    /// The `{type, tname, item, assoc}` hash Yjs uses (RelativePosition's
    /// JSON), which editors carry in awareness as `anchorPos`/`focusPos`.
    pub fn to_ruby(&self, ruby: &Ruby) -> Result<RHash, Error> {
        let id = |id: &yrs::block::ID| -> Result<RHash, Error> {
            let h = ruby.hash_new();
            h.aset("client", id.client.get())?;
            h.aset("clock", id.clock)?;
            Ok(h)
        };
        let h = ruby.hash_new();
        h.aset("type", ruby.qnil())?;
        h.aset("tname", ruby.qnil())?;
        h.aset("item", ruby.qnil())?;
        match &self.scope {
            IndexScope::Relative(item) => h.aset("item", id(item)?)?,
            IndexScope::Nested(ty) => h.aset("type", id(ty)?)?,
            IndexScope::Root(name) => h.aset("tname", name.to_string())?,
        }
        h.aset("assoc", self.assoc)?;
        Ok(h)
    }
}

// --- values ---

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

/// Read a Ruby Hash into `Send` pairs with the GVL held.
pub fn hash_pairs(ruby: &Ruby, hash: RHash) -> Result<Vec<(String, InValue)>, Error> {
    let mut pairs = Vec::new();
    hash.foreach(|k: Value, v: Value| {
        pairs.push((key_to_string(k)?, ruby_to_invalue(ruby, v)?));
        Ok(ForEach::Continue)
    })?;
    Ok(pairs)
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
        return Ok(InValue::Map(hash_pairs(ruby, h)?));
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

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::{Doc, GetString, OffsetKind, Options, Transact};

    fn utf16_doc() -> Doc {
        Doc::with_options(Options {
            offset_kind: OffsetKind::Utf16,
            ..Options::default()
        })
    }

    #[test]
    fn insert_index_reads_negative_indexes_as_ruby_does() {
        assert_eq!(insert_index(0, 3), 0);
        assert_eq!(insert_index(-1, 3), 3);
        assert_eq!(insert_index(-4, 3), 0);
        assert_eq!(insert_index(99, 3), 3);
    }

    #[test]
    fn element_index_is_none_outside() {
        assert_eq!(element_index(-1, 3), Some(2));
        assert_eq!(element_index(3, 3), None);
        assert_eq!(element_index(-4, 3), None);
    }

    #[test]
    fn delete_span_follows_slice_bang() {
        assert_eq!(delete_span(1, 1, 3), Some((1, 2)));
        assert_eq!(delete_span(-1, 5, 3), Some((2, 3)));
        assert_eq!(delete_span(3, 1, 3), Some((3, 3)));
        assert_eq!(delete_span(4, 1, 3), None);
        assert_eq!(delete_span(-4, 1, 3), None);
    }

    #[test]
    fn characters_map_to_utf16_units_and_back() {
        let doc = utf16_doc();
        let text = doc.get_or_insert_text("t");
        let mut txn = doc.transact_mut();
        text.insert(&mut txn, 0, "a😀é日");
        assert_eq!(char_len(&txn, &text), 4);
        assert_eq!(to_units(&txn, &text, 2), 3);
        assert_eq!(to_units(&txn, &text, 4), 5);
        assert_eq!(to_chars(&txn, &text, 3), 2);
        let from = to_units(&txn, &text, 1);
        text.remove_range(&mut txn, from, 2);
        assert_eq!(text.get_string(&txn), "aé日");
    }
}
