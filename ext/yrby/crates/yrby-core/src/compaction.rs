//! Snapshot-plus-tail storage, as a store needs it: merging on load and
//! planning compactions. Pure functions over bytes; a store runs the SQL.
//!
//! A document is stored as a snapshot (`state`) plus a tail of update rows
//! appended since. Compaction folds the tail into the snapshot and deletes
//! what it folded. A row whose dependency has not arrived (a causal gap)
//! cannot be folded; it stays in the tail, marked pending, until the
//! dependency arrives. This is `Y::Document#compact!` from yrby-rails.

use yrs::updates::decoder::Decode;
use yrs::{Doc, ReadTxn, StateVector, Transact, Update};

use crate::protocol::{has_pending, integrated_update, update_advances_doc, update_is_ready};

pub type CompactionError = Box<dyn std::error::Error + Send + Sync>;

/// What a compaction should do, all in one transaction.
#[derive(Debug, Default, PartialEq)]
pub struct CompactionPlan {
    /// The new snapshot, or `None` to leave the snapshot as it is.
    pub state: Option<Vec<u8>>,
    /// Rows now fully captured by the snapshot.
    pub delete: Vec<i64>,
    /// Rows that carry or build on a causal gap. They stay, marked pending.
    pub quarantine: Vec<i64>,
}

fn apply(doc: &Doc, update: &[u8]) -> Result<(), CompactionError> {
    doc.transact_mut()
        .apply_update(Update::decode_v1(update)?)?;
    Ok(())
}

fn fold<'a>(
    state: Option<&[u8]>,
    rows: impl IntoIterator<Item = &'a [u8]>,
) -> Result<Doc, CompactionError> {
    let doc = Doc::new();
    if let Some(state) = state {
        apply(&doc, state)?;
    }
    for row in rows {
        apply(&doc, row)?;
    }
    Ok(doc)
}

/// The document a load serves: the snapshot plus every tail row, pending
/// rows included. The encoding is lossless, so an unhealed gap travels as a
/// pending struct and a peer heals it when the dependency arrives.
///
/// Read the tail *before* the snapshot. A compaction that commits between the
/// two reads then pairs a fresh snapshot with rows it already holds (applying
/// twice is harmless), where the other order could pair an old snapshot with
/// an emptied tail and lose committed changes.
pub fn merged_state(
    state: Option<&[u8]>,
    tail: &[Vec<u8>],
) -> Result<Option<Vec<u8>>, CompactionError> {
    if tail.is_empty() {
        return Ok(state.map(<[u8]>::to_vec));
    }
    let doc = fold(state, tail.iter().map(Vec::as_slice))?;
    Ok(Some(
        doc.transact()
            .encode_state_as_update_v1(&StateVector::default()),
    ))
}

/// Plan folding `rows` (every tail row, pending or not, as `(id, payload)`)
/// into `state`.
///
/// Without a gap, everything folds and every row goes. With one, everything
/// that integrates still folds into the snapshot, however it interleaves with
/// the gap, and each row is then judged against the new snapshot: a row that
/// is not ready, or that still adds something, carries the gap and is
/// quarantined; a row that is ready and adds nothing is captured and deleted.
/// An acknowledged update never leaves the table before its content is in the
/// snapshot.
pub fn plan(
    state: Option<&[u8]>,
    rows: &[(i64, Vec<u8>)],
) -> Result<CompactionPlan, CompactionError> {
    if rows.is_empty() {
        return Ok(CompactionPlan::default());
    }
    let folded = fold(state, rows.iter().map(|(_, payload)| payload.as_slice()))?;
    let new_state = integrated_update(&folded, &StateVector::default())?;
    if !has_pending(&folded) {
        return Ok(CompactionPlan {
            state: Some(new_state),
            delete: rows.iter().map(|(id, _)| *id).collect(),
            quarantine: Vec::new(),
        });
    }

    // Skip the write when nothing integrated beyond the current snapshot. The
    // integrated encoding is deterministic, so equal structs give equal bytes.
    let current = integrated_update(&fold(state, [])?, &StateVector::default())?;
    let changed = new_state != current;

    let base = fold(Some(&new_state), [])?;
    let mut plan = CompactionPlan {
        state: changed.then(|| new_state.clone()),
        ..Default::default()
    };
    for (id, payload) in rows {
        if !update_is_ready(&base, payload)? || update_advances_doc(&base, payload)? {
            plan.quarantine.push(*id);
        } else {
            plan.delete.push(*id);
        }
    }
    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::{GetString, Text};

    /// Successive edits by one client to one text, each as its own update.
    fn edits(parts: &[&str]) -> Vec<Vec<u8>> {
        let doc = Doc::new();
        let text = doc.get_or_insert_text("t");
        parts
            .iter()
            .map(|part| {
                let mut txn = doc.transact_mut();
                let len = text.len(&txn);
                text.insert(&mut txn, len, part);
                txn.encode_update_v1()
            })
            .collect()
    }

    fn text(state: &[u8]) -> String {
        let doc = fold(Some(state), []).unwrap();
        let text = doc.get_or_insert_text("t");
        text.get_string(&doc.transact())
    }

    fn rows(updates: &[Vec<u8>], ids: &[i64]) -> Vec<(i64, Vec<u8>)> {
        ids.iter()
            .zip(updates)
            .map(|(id, u)| (*id, u.clone()))
            .collect()
    }

    #[test]
    fn folds_a_clean_tail_and_deletes_every_row() {
        let updates = edits(&["a", "b", "c"]);
        let plan = plan(None, &rows(&updates, &[1, 2, 3])).unwrap();
        assert_eq!(plan.delete, vec![1, 2, 3]);
        assert!(plan.quarantine.is_empty());
        assert_eq!(text(&plan.state.unwrap()), "abc");
    }

    #[test]
    fn folds_onto_an_existing_snapshot() {
        let updates = edits(&["a", "b", "c"]);
        let first = plan(None, &rows(&updates[..1], &[1]))
            .unwrap()
            .state
            .unwrap();
        let second = plan(Some(&first), &rows(&updates[1..], &[2, 3])).unwrap();
        assert_eq!(text(&second.state.unwrap()), "abc");
    }

    #[test]
    fn duplicates_fold_harmlessly() {
        let updates = edits(&["a"]);
        let plan = plan(None, &[(1, updates[0].clone()), (2, updates[0].clone())]).unwrap();
        assert_eq!(plan.delete, vec![1, 2]);
        assert_eq!(text(&plan.state.unwrap()), "a");
    }

    #[test]
    fn quarantines_the_gap_and_folds_the_rest() {
        // Client X: "a" then "b"; the "a" row is missing, so "b" is gapped.
        let x = edits(&["a", "b"]);
        // Client Y edits independently of X.
        let y = edits(&["y"]);
        let plan = plan(None, &[(1, y[0].clone()), (2, x[1].clone())]).unwrap();

        assert_eq!(plan.delete, vec![1], "the independent row folds");
        assert_eq!(plan.quarantine, vec![2], "the gapped row waits");
        assert_eq!(text(&plan.state.unwrap()), "y");
    }

    #[test]
    fn a_gap_only_batch_leaves_the_snapshot_alone() {
        let x = edits(&["a", "b"]);
        let plan = plan(None, &[(7, x[1].clone())]).unwrap();
        assert_eq!(plan.state, None);
        assert_eq!(plan.quarantine, vec![7]);
        assert!(plan.delete.is_empty());
    }

    #[test]
    fn the_gap_heals_when_its_dependency_arrives() {
        let x = edits(&["a", "b"]);
        // First compaction quarantines "b"; then "a" arrives as a new row.
        let first = plan(None, &[(1, x[1].clone())]).unwrap();
        assert_eq!(first.quarantine, vec![1]);
        let healed = plan(None, &[(1, x[1].clone()), (2, x[0].clone())]).unwrap();
        assert_eq!(healed.delete, vec![1, 2]);
        assert!(healed.quarantine.is_empty());
        assert_eq!(text(&healed.state.unwrap()), "ab");
    }

    #[test]
    fn merged_state_includes_the_tail_and_pending_rows() {
        let x = edits(&["a", "b", "c"]);
        let snapshot = plan(None, &rows(&x[..1], &[1])).unwrap().state.unwrap();
        // Tail holds "c" (gapped: "b" missing) and then "b" (which heals it).
        let merged = merged_state(Some(&snapshot), &[x[2].clone(), x[1].clone()])
            .unwrap()
            .unwrap();
        assert_eq!(text(&merged), "abc");
        // A still-open gap rides along instead of being dropped.
        let gapped = merged_state(Some(&snapshot), &[x[2].clone()])
            .unwrap()
            .unwrap();
        let doc = fold(Some(&gapped), []).unwrap();
        assert!(has_pending(&doc));
        assert_eq!(merged_state(None, &[]).unwrap(), None);
    }
}
