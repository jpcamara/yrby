//! The pure part of ext/yrby/src/shared.rs, copied for the spike: origins,
//! branch identity, and Ruby-character indexes. A real migration would move
//! these into their own magnus-free module that both builds include.

use yrs::branch::BranchID;
use yrs::types::text::YChange;
use yrs::{Any, Hook, Out, ReadTxn, SharedRef, Text};

/// The origin of every transaction a handle opens, all through `write`.
pub const ORIGIN: &str = "yrby";

/// What the origin of every transaction that applies a peer's update starts
/// with. The document keeps every other transaction's update for `Doc#edit`.
pub const REMOTE: &str = "yrby-remote";

/// True when `origin` marks a transaction that applied a peer's update.
pub fn is_remote(origin: Option<&yrs::Origin>) -> bool {
    origin.is_some_and(|origin| origin.as_ref().starts_with(REMOTE.as_bytes()))
}

/// The branch `id` names, if it exists and has not been deleted.
pub fn resolve<S: SharedRef, T: ReadTxn>(txn: &T, id: &BranchID) -> Option<S> {
    Hook::<S>::from(id.clone()).get(txn)
}

/// The identity a handle keeps for `shared`.
pub fn identity<S: SharedRef>(shared: &S) -> BranchID {
    shared.hook().into()
}

/// What `insert(index, ...)` means in a sequence of `len`, as in Ruby: a
/// negative index counts from the end, so -1 is the end itself. Clamped.
pub fn insert_index(index: i64, len: u32) -> u32 {
    let len = len as i64;
    let i = if index < 0 { len + index + 1 } else { index };
    i.clamp(0, len) as u32
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
