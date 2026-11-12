//! The Yjs operations pg_yrby exposes, as plain Rust over v1-encoded bytes.
//! Nothing here touches Postgres.
//!
//! A stored document is a v1 update: the integrated state plus anything still
//! waiting on a missing dependency (pending). Pending content is kept so a
//! later update can heal the gap, but it is never served in a diff.
//!
//! Updates are combined with `merge_updates_v1`, never by applying them one
//! after another to a yrs `Doc` that holds pending content. Re-encoding a
//! `Doc` that holds pending content can lose some, and in yrs 0.27
//! out-of-order delivery through a `Doc` could leave content stuck as
//! pending for good (tests/js/converge.mjs found both; JS Yjs handles the
//! same orders).
//! Merging is a set union of structs and deletions, so it cannot lose
//! anything. A `Doc` is only used to read, and to re-encode a merged update
//! that has no gaps.
//!
//! For the same reason nothing stored is ever pruned of pending content.
//! yrby-core's `compaction::plan` keeps a gap-free snapshot and leaves gapped
//! rows in the log; with out-of-order rows it can drop content
//! (tests/fixtures/out-of-order). Here a snapshot is just a ydoc: compaction
//! merges the log into it with `ydoc_apply`/`ydoc_merge_agg` and deletes
//! every folded row, and pending content waits inside the snapshot. Serving
//! stays gap-free because `diff` strips pending content on the way out.

use yrs::types::ToJson;
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Any, Doc, GetString, IdSet, Map, Out, ReadTxn, StateVector, Transact, Update, WriteTxn};

pub type Error = Box<dyn std::error::Error + Send + Sync>;

/// An empty document, encoded: no structs and an empty delete set.
pub const EMPTY: [u8; 2] = [0, 0];

/// Load a document from a v1 update. Empty bytes load an empty document.
pub fn load(bytes: &[u8]) -> Result<Doc, Error> {
    let doc = Doc::new();
    if !bytes.is_empty() {
        doc.transact_mut().apply_update(Update::decode_v1(bytes)?)?;
    }
    Ok(doc)
}

/// The lossless encoding of a document: integrated state plus pending.
pub fn encode(doc: &Doc) -> Vec<u8> {
    doc.transact()
        .encode_state_as_update_v1(&StateVector::default())
}

/// Check that `bytes` decode as a v1 update.
pub fn validate(bytes: &[u8]) -> Result<(), Error> {
    Update::decode_v1(bytes)?;
    Ok(())
}

/// The stored form of a merged update: re-encoded through a `Doc` when it
/// has no gaps (garbage-collected and compact), kept as merged otherwise.
fn settle(merged: Vec<u8>) -> Result<Vec<u8>, Error> {
    let doc = load(&merged)?;
    if has_pending(&doc) {
        return Ok(merged);
    }
    let encoded = encode(&doc);
    // Belt and braces: never trade the merged form for one that lost a struct
    // or a deletion.
    Ok(if contains(&encoded, &merged)? { encoded } else { merged })
}

/// Apply `update` to `doc`. Returns `None` when the stored bytes would not
/// change, so the caller can keep the value it has.
///
/// An update that has to wait on a missing dependency is kept in the value
/// until the dependency arrives. Values this function produces settle to
/// themselves, so an update the document already has returns `None`; a
/// value that came from elsewhere may be rewritten once.
pub fn apply(doc: &[u8], update: &[u8]) -> Result<Option<Vec<u8>>, Error> {
    // Fast path, the common case: nothing pending before or after, so a
    // plain apply through a Doc is safe. Anything pending takes the merge.
    let loaded = load(doc)?;
    let decoded = Update::decode_v1(update)?;
    let next = if !has_pending(&loaded) {
        loaded.transact_mut().apply_update(decoded)?;
        if has_pending(&loaded) {
            settle(merge(&[doc, update])?)?
        } else {
            encode(&loaded)
        }
    } else {
        settle(merge(&[doc, update])?)?
    };
    Ok((next != doc).then_some(next))
}

/// True if applying `update` would change the document: new content, a new
/// deletion, or an update that has to wait on a missing dependency.
pub fn adds(doc: &[u8], update: &[u8]) -> Result<bool, Error> {
    Ok(!contains(doc, update)?)
}

/// True if `doc` already holds everything in `update`: every struct (by ID,
/// deleted or garbage-collected ones included) and every deletion. Read from
/// the encodings alone, so a gap in either side cannot hide anything, which
/// comparing loaded documents can (yrs caps a state vector at its first hole).
pub fn contains(doc: &[u8], update: &[u8]) -> Result<bool, Error> {
    let update = Update::decode_v1(update)?;
    let doc = if doc.is_empty() { Update::decode_v1(&EMPTY)? } else { Update::decode_v1(doc)? };
    Ok(covered(&update.insertions(true), &doc.insertions(true))
        && covered(update.delete_set(), doc.delete_set()))
}

fn covered(part: &IdSet, whole: &IdSet) -> bool {
    part.diff(whole).iter().all(|(_, ranges)| ranges.is_empty())
}

/// Merge updates without loading a document. The result is a valid update
/// that carries everything the inputs carry, gaps included.
pub fn merge<B: AsRef<[u8]>>(updates: &[B]) -> Result<Vec<u8>, Error> {
    let parts: Vec<&[u8]> = updates
        .iter()
        .map(AsRef::as_ref)
        .filter(|u| !u.is_empty())
        .collect();
    match parts.len() {
        0 => Ok(EMPTY.to_vec()),
        1 => {
            validate(parts[0])?;
            Ok(parts[0].to_vec())
        }
        _ => Ok(yrs::merge_updates_v1(parts)?),
    }
}

/// The document's state vector (integrated state only), v1-encoded. This is
/// what a sync step 1 sends.
pub fn state_vector(doc: &[u8]) -> Result<Vec<u8>, Error> {
    Ok(load(doc)?.transact().state_vector().encode_v1())
}

/// True if the document holds structs or deletions waiting on a missing
/// dependency.
fn has_pending(doc: &Doc) -> bool {
    let txn = doc.transact();
    txn.store().pending_update().is_some() || txn.store().pending_ds().is_some()
}

/// The document's integrated state diffed against `sv`, without pending
/// content. `encode_state_as_update_v1` merges pending back in, so when there
/// is any, rebuild the state in a scratch `Doc` and prune it there. The
/// stored document keeps its pending content.
fn integrated_update(doc: &Doc, sv: &StateVector) -> Result<Vec<u8>, Error> {
    let full = {
        let txn = doc.transact();
        let store = txn.store();
        if store.pending_update().is_none() && store.pending_ds().is_none() {
            return Ok(txn.encode_state_as_update_v1(sv));
        }
        txn.encode_state_as_update_v1(&StateVector::default())
    };
    let clean = Doc::new();
    {
        let mut txn = clean.transact_mut();
        txn.apply_update(Update::decode_v1(&full)?)?;
        txn.prune_pending();
    }
    let out = clean.transact().encode_state_as_update_v1(sv);
    Ok(out)
}

/// What a peer with state vector `sv` is missing, as a v1 update. Pending
/// content is left out: a peer could not integrate it either.
pub fn diff(doc: &[u8], sv: &[u8]) -> Result<Vec<u8>, Error> {
    let sv = if sv.is_empty() {
        StateVector::default()
    } else {
        StateVector::decode_v1(sv)?
    };
    integrated_update(&load(doc)?, &sv)
}

/// What a peer with state vector `sv` is missing, pending content included,
/// as Yjs's `encodeStateAsUpdate` serves it: a peer parks the pending part
/// and heals when the missing update reaches it. Diffed from the stored
/// update directly, without loading a `Doc`, so nothing can be dropped.
pub fn diff_with_pending(doc: &[u8], sv: &[u8]) -> Result<Vec<u8>, Error> {
    let sv = if sv.is_empty() {
        StateVector::default().encode_v1()
    } else {
        sv.to_vec()
    };
    let doc = if doc.is_empty() { &EMPTY[..] } else { doc };
    Ok(yrs::diff_updates_v1(doc, &sv)?)
}

/// True if the document holds content waiting on a missing dependency.
pub fn pending(doc: &[u8]) -> Result<bool, Error> {
    Ok(has_pending(&load(doc)?))
}

/// Document equality: same integrated content and deletions (a Yjs snapshot).
/// Documents with pending content are equal only if they also merge to the
/// same bytes, which is conservative.
pub fn equal(a: &[u8], b: &[u8]) -> Result<bool, Error> {
    if a == b {
        return Ok(true);
    }
    let (da, db) = (load(a)?, load(b)?);
    if da.transact().snapshot() != db.transact().snapshot() {
        return Ok(false);
    }
    if has_pending(&da) || has_pending(&db) {
        return Ok(merge(&[a, &EMPTY])? == merge(&[b, &EMPTY])?);
    }
    Ok(true)
}

/// The plain text of the root text named `name`, or `None` if there is none.
pub fn text(doc: &[u8], name: &str) -> Result<Option<String>, Error> {
    let doc = load(doc)?;
    let txn = doc.transact();
    Ok(txn.get_text(name).map(|t| t.get_string(&txn)))
}

/// The root map named `name` as JSON.
pub fn map_json(doc: &[u8], name: &str) -> Result<Option<String>, Error> {
    let doc = load(doc)?;
    let txn = doc.transact();
    Ok(txn.get_map(name).map(|m| any_json(&m.to_json(&txn))))
}

/// The root array named `name` as JSON.
pub fn array_json(doc: &[u8], name: &str) -> Result<Option<String>, Error> {
    let doc = load(doc)?;
    let txn = doc.transact();
    Ok(txn.get_array(name).map(|a| any_json(&a.to_json(&txn))))
}

/// The root XML fragment named `name` as an XML string.
pub fn xml(doc: &[u8], name: &str) -> Result<Option<String>, Error> {
    let doc = load(doc)?;
    let txn = doc.transact();
    Ok(txn.get_xml_fragment(name).map(|x| x.get_string(&txn)))
}

/// Every root as JSON. A document loaded from bytes does not know its root
/// types, so each is inferred from its content the way yrs does it: a map, an
/// array, text (as a string), or XML (as a string).
pub fn json(doc: &[u8]) -> Result<String, Error> {
    let source = load(doc)?;
    let txn = source.transact();
    // Copy each root into a map on a scratch doc. Inserting yrs's prelim of an
    // untyped root makes yrs infer the type, which typed reads can then use.
    let scratch = Doc::new();
    let roots = scratch.get_or_insert_map("roots");
    {
        let mut out = scratch.transact_mut();
        for (name, value) in txn.root_refs() {
            let prelim = yrs::types::AsPrelim::as_prelim(&value, &txn);
            roots.insert(&mut out, name, prelim);
        }
    }
    let out = scratch.transact();
    let mut json = std::collections::HashMap::new();
    for (name, value) in roots.iter(&out) {
        let any = match value {
            Out::YText(t) => Any::from(t.get_string(&out)),
            Out::YXmlText(t) => Any::from(t.get_string(&out)),
            Out::YXmlElement(x) => Any::from(x.get_string(&out)),
            Out::YXmlFragment(x) => Any::from(x.get_string(&out)),
            other => other.to_json(&out),
        };
        json.insert(name.to_string(), any);
    }
    Ok(any_json(&Any::from(json)))
}

fn any_json(any: &Any) -> String {
    let mut buf = String::new();
    any.to_json(&mut buf);
    buf
}
