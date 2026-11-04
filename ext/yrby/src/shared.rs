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
use yrs::branch::{Branch, BranchID, BranchPtr};
use yrs::types::text::YChange;
use yrs::{
    Any, Doc, Hook, In, IndexScope, MapPrelim, Number, Out, ReadTxn, SharedRef, StickyIndex, Text,
    Transact, TransactionMut, Xml, XmlOut, XmlTextRef,
};

use crate::{nogvl, yrb_error};

/// The origin of every transaction a handle opens, all through `write`.
pub const ORIGIN: &str = "yrby";

/// The largest integer a double represents exactly (2^53).
const MAX_SAFE_INTEGER: u64 = 1 << 53;

/// A key no other observer uses. yrs registers an observer under a key and
/// removes it by that key, so two observers on one document need different
/// ones.
pub fn observer_key() -> yrs::Origin {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        .into()
}

/// The branch `id` names, if it exists and has not been deleted.
pub fn resolve<S: SharedRef, T: ReadTxn>(txn: &T, id: &BranchID) -> Option<S> {
    Hook::<S>::from(id.clone()).get(txn)
}

/// The identity a handle keeps for `shared`.
pub fn identity<S: SharedRef>(shared: &S) -> BranchID {
    shared.hook().into()
}

/// A value stored in a map or an array, as the handle it takes: its kind
/// and identity. Read it inside the transaction. The value's branch pointer
/// can't leave it, since another thread can delete the branch, and its
/// commit frees it.
pub enum Child {
    Map(BranchID),
    Array(BranchID),
    Text(BranchID),
    /// A plain value, or nothing at all.
    Other,
}

impl Child {
    pub fn of(value: Option<Out>) -> Child {
        match value {
            Some(Out::YMap(m)) => Child::Map(identity(&m)),
            Some(Out::YArray(a)) => Child::Array(identity(&a)),
            Some(Out::YText(t)) => Child::Text(identity(&t)),
            _ => Child::Other,
        }
    }
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
    })?
    .map_err(yrb_error)
}

/// Run `f` in a write transaction under `ORIGIN`, as `guarded` runs its
/// closure. When a `Doc#edit` is running in this fiber, the update the
/// transaction made goes to it, so an edit returns its own writes and none
/// another fiber, thread, or peer made meanwhile.
pub fn write<F, R>(doc: &Doc, f: F) -> Result<R, Error>
where
    F: FnOnce(&mut TransactionMut) -> Result<R, String> + Send,
    R: Send,
{
    let edit = current_edit()?;
    let recording = edit.is_some();
    let (result, update) = guarded(move || {
        let mut txn = doc.transact_mut_with(ORIGIN);
        let result = f(&mut txn);
        let changed = !txn.insert_set().is_empty() || !txn.delete_set().is_empty();
        Ok((
            result,
            (recording && changed).then(|| txn.encode_update_v1()),
        ))
    })?;
    if let (Some(edit), Some(update)) = (edit, update) {
        edit.push(crate::binary_string(&update))?;
    }
    result.map_err(yrb_error)
}

/// The updates collected by the innermost `Doc#edit` running in this fiber,
/// or None outside one. `Thread#[]` is fiber-local.
fn current_edit() -> Result<Option<RArray>, Error> {
    let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
    let edits: Option<RArray> = ruby
        .thread_current()
        .funcall("[]", (ruby.to_symbol("yrby_edits"),))?;
    match edits {
        Some(edits) if !edits.is_empty() => Ok(Some(edits.entry(-1)?)),
        _ => Ok(None),
    }
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

/// The document index for `insert(index, ...)`. Appending (-1), what a
/// streaming writer does chunk after chunk, goes straight to the end without
/// walking the sequence.
pub fn end_or_units<T: ReadTxn, S: Text>(txn: &T, seq: &S, index: i64) -> u32 {
    if index == -1 {
        seq.len(txn)
    } else {
        to_units(txn, seq, insert_index(index, char_len(txn, seq)))
    }
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

/// The root `branch` lives under, found by walking up its XML parents.
pub fn top(branch: BranchPtr) -> BranchPtr {
    let mut at = branch;
    while let Some(parent) = XmlTextRef::from(at).parent() {
        let branch: &Branch = match &parent {
            XmlOut::Element(e) => e.as_ref(),
            XmlOut::Fragment(f) => f.as_ref(),
            XmlOut::Text(t) => t.as_ref(),
        };
        at = BranchPtr::from(branch);
    }
    at
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
    pairs_at(ruby, hash, 0)
}

/// How deep a Hash or Array written to a document may nest, as many levels as
/// JSON's default `max_nesting`. Converting one that contains itself would
/// otherwise recurse until the stack overflows.
pub const MAX_NESTING: usize = 100;

fn pairs_at(ruby: &Ruby, hash: RHash, depth: usize) -> Result<Vec<(String, InValue)>, Error> {
    let mut pairs = Vec::new();
    hash.foreach(|k: Value, v: Value| {
        pairs.push((key_to_string(k)?, invalue_at(ruby, v, depth)?));
        Ok(ForEach::Continue)
    })?;
    Ok(pairs)
}

/// Read a Ruby value into an `InValue`. GVL held. Ruby `Hash` becomes a live
/// nested map; `Array` an embedded array of primitives; primitives their `Any`.
pub fn ruby_to_invalue(ruby: &Ruby, v: Value) -> Result<InValue, Error> {
    invalue_at(ruby, v, 0)
}

fn invalue_at(ruby: &Ruby, v: Value, depth: usize) -> Result<InValue, Error> {
    if depth > MAX_NESTING {
        return Err(Error::new(
            ruby.exception_arg_error(),
            format!("nesting of {depth} is too deep (at most {MAX_NESTING})"),
        ));
    }
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
        return Ok(InValue::Map(pairs_at(ruby, h, depth + 1)?));
    }
    if let Some(a) = RArray::from_value(v) {
        let mut items: Vec<Any> = Vec::with_capacity(a.len());
        for item in a.into_iter() {
            items.push(invalue_to_any(invalue_at(ruby, item, depth + 1)?));
        }
        return Ok(InValue::Any(Any::Array(items.into())));
    }
    if let Some(i) = Integer::from_value(v) {
        // yrs encodes an integer as a plain number whenever a double holds it,
        // so JavaScript reads a number, not a BigInt that would break
        // JSON.stringify and the bitwise math editors do on flags like
        // `__format`.
        return Ok(InValue::Any(Any::Number(Number::Int(i.to_i64()?))));
    }
    if let Some(f) = Float::from_value(v) {
        return Ok(InValue::Any(Any::Number(Number::Float(f.to_f64()))));
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
        Any::Number(Number::Int(i)) => (*i).into_value_with(ruby),
        // A whole number reads back as an Integer, as JSON.parse would give.
        Any::Number(Number::Float(n)) if n.fract() == 0.0 && n.abs() <= MAX_SAFE_INTEGER as f64 => {
            (*n as i64).into_value_with(ruby)
        }
        Any::Number(Number::Float(n)) => (*n).into_value_with(ruby),
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

/// What the handle tests share: a document set up as `Y::Doc.new` sets one
/// up, and Ruby values to call handle methods with. Tests that use these run
/// inside Ruby (`#[ruby_test]`), since the handles call into it.
#[cfg(test)]
pub mod test_support {
    use magnus::{IntoValue, RHash, Ruby, Value};
    use yrs::{Any, Doc, Number, OffsetKind, Options};

    /// A document that counts text as `Y::Doc.new` does, in UTF-16 units.
    pub fn doc() -> Doc {
        Doc::with_options(Options {
            offset_kind: OffsetKind::Utf16,
            ..Options::default()
        })
    }

    pub fn rb<T: IntoValue>(value: T) -> Value {
        Ruby::get().unwrap().into_value(value)
    }

    pub fn hash(pairs: &[(&str, Value)]) -> RHash {
        let hash = Ruby::get().unwrap().hash_new();
        for (key, value) in pairs {
            hash.aset(*key, *value).unwrap();
        }
        hash
    }

    pub fn int(value: i64) -> Any {
        Any::Number(Number::Int(value))
    }
}
