# pg_ydoc

A Postgres extension, in Rust with [pgrx](https://github.com/pgcentralfoundation/pgrx),
that stores [Yjs](https://yjs.dev) documents in a `ydoc` column and runs the
sync operations a Yjs server needs in SQL. Built on
[yrs](https://github.com/y-crdt/y-crdt) 0.28.

```sql
CREATE EXTENSION pg_ydoc;
CREATE TABLE notes (id bigint PRIMARY KEY, body ydoc);

-- A client sends a v1 update.
UPDATE notes SET body = ydoc_apply(body, $1) WHERE id = 1;

-- Sync step 1 and 2.
SELECT ydoc_state_vector(body) FROM notes WHERE id = 1;
SELECT ydoc_diff(body, $client_state_vector) FROM notes WHERE id = 1;

-- Read it.
SELECT ydoc_text(body, 'content'), ydoc_json(body) FROM notes;
```

## Functions

Updates and state vectors are `bytea` in the v1 encoding Yjs clients use.

| Function | Returns | |
|---|---|---|
| `ydoc()` | `ydoc` | An empty document. |
| `ydoc(bytea)`, `bytea::ydoc` | `ydoc` | A document from a v1 update, validated. `ydoc::bytea` is free. |
| `ydoc_apply(ydoc, bytea)` | `ydoc` | Apply an update. A NULL document counts as empty. Gives back the same value when the update changes nothing. |
| `ydoc_adds(ydoc, bytea)` | `bool` | Would the update change anything (new content, a new deletion, or a gap to wait on)? Read from the encodings, so it is cheap. |
| `ydoc_state_vector(ydoc, gapless bool = false)` | `bytea` | Sync step 1: per client, the clocks stored contiguously from zero. Read without loading the document, so content waiting on another client's missing update still counts. With `gapless`, NULL when the document holds content past a gap, for the stored column below. |
| `ydoc_fits(update bytea, sv bytea)` | `bool` | Does everything the update inserts or deletes lie below `sv`? With `sv` from `ydoc_state_vector` of a snapshot plus its log, the log rows that can fold without leaving a gap in the snapshot. |
| `ydoc_extend_state_vector(sv bytea, ydoc)` | `bytea` | `sv` advanced by what the update adds contiguously after it: a snapshot's stored state vector plus its log, without decoding the snapshot. |
| `ydoc_diff(ydoc, sv bytea = NULL, include_pending bool = false)` | `bytea` | Sync step 2: what a peer with `sv` is missing; the whole document without `sv`. Leaves out pending content unless `include_pending`, which serves it as Yjs's `encodeStateAsUpdate` does, so the peer holds the gap and heals when the missing update reaches it. With `include_pending` and an empty `sv`, the stored bytes as they are, without decoding. NULL for a NULL document. |
| `ydoc_has_pending(ydoc)` | `bool` | Does the document hold updates waiting on a missing dependency? |
| `ydoc_merge(ydoc, ydoc)` | `ydoc` | Merge two documents without loading them. |
| `ydoc_merge_agg(bytea)`, `ydoc_merge_agg(ydoc)` | `ydoc` | Aggregate: merge any number of updates in any order. NULL when there are none. |
| `ydoc_text(ydoc, name)` | `text` | A root text as plain text. |
| `ydoc_map(ydoc, name)`, `ydoc_array(ydoc, name)` | `jsonb` | A root map or array. |
| `ydoc_xml(ydoc, name)` | `text` | A root XML fragment as XML. |
| `ydoc_json(ydoc)` | `jsonb` | Every root, each type inferred from its content (texts become strings). An XML fragment of nested elements looks like an array to inference; read it with `ydoc_xml`. |
| `=`, `<>` | `bool` | Same content and deletions (a Yjs snapshot), not byte equality. |

All NULL handling is SQL-standard except `ydoc_apply`, which treats a NULL
document as empty and a NULL update as a no-op.

## Updates that arrive early

An update whose dependency has not arrived yet (a causal gap) is kept inside
the stored value, and folds in when the missing update comes. It is never
dropped, and `ydoc_has_pending` reports it. `ydoc_diff` leaves it out by
default; `include_pending => true` sends it along, as Yjs servers do.

To make that hold, pg_ydoc combines updates with `merge_updates_v1` whenever
anything is pending, never by applying them one after another to a yrs `Doc`.
The convergence test found that re-encoding a `Doc` that holds pending
content can lose some, and that in yrs 0.27 out-of-order delivery through a
`Doc` could leave content stuck as pending for good (fixed in 0.28.1). JS Yjs
handles the same update orders fine. The failing orders are kept as fixtures in `tests/fixtures/out-of-order`.

## Storage: merged document or snapshot plus log

A `ydoc` column rewrites the whole document on every change: a new row
version, a new copy in TOAST, and all of it in the WAL. For a document edited
often, keep a snapshot, append updates to a log, and fold the log into the
snapshot once the log's bytes reach a share of the snapshot's (10% here, at
least 4 KB). A large document is then rewritten rarely, and the cost of a
compaction per edit stays about the same at any size.

Keep the log insert-only. Compaction records the MVCC snapshot it folded
under (`pg_current_snapshot()`) instead of deleting rows, and reads skip the
rows that snapshot covers. The log has two partitions; rotation copies the
older one's unfolded rows into the current one, truncates it, and makes it
current. The log then leaves no dead tuples: what remains are the snapshot
rewrites.

Serve a client without decoding the snapshot. Keep its state vector in a
generated column and extend it by the log for sync step 1. For step 2 send
the snapshot's part and the log's part as two updates, snapshot first; a
client with nothing gets the snapshot's bytes as stored. For that the
snapshot must hold no content past a gap, so compaction folds only the rows
that fit (`ydoc_fits`) and writes the rest again as new, unfolded rows, to
fold once the gap closes. A snapshot that still holds content past a gap
has no stored state vector (`gapless => true` gives NULL) and is served
merged instead.

Measured on a Mac mini (PG 17, one-character edits, one statement each,
compactions and rotations counted, autovacuum off; joins timed with the log
halfway to its next compaction; `tests/js/storage_bench.mjs`). "64 rows"
compacts every 64 rows, deletes them and serves merged; "deleting" is the
size policy and split serving with a deleting log:

| Starting doc | Storage | WAL per edit | Dead tuples per edit | Per edit | New client joins | Returning client joins |
|---|---|---|---|---|---|---|
| 2 KB | merged `ydoc` | 1.9 KB | 0.24 | 0.28 ms | 0.25 ms | 0.19 ms |
| 2 KB | snapshot + log, 64 rows | 0.36 KB | 1.03 | 0.24 ms | 0.81 ms | 0.80 ms |
| 2 KB | snapshot + log, deleting | 0.34 KB | 1.01 | 0.11 ms | 0.48 ms | 0.48 ms |
| 2 KB | snapshot + log, truncating | 0.24 KB | 0.01 | 0.16 ms | 0.52 ms | 0.56 ms |
| 50 KB | merged `ydoc` | 30.0 KB | 14.1 | 1.89 ms | 0.48 ms | 0.50 ms |
| 50 KB | snapshot + log, 64 rows | 0.79 KB | 1.22 | 0.20 ms | 1.24 ms | 1.32 ms |
| 50 KB | snapshot + log, deleting | 0.52 KB | 1.09 | 0.17 ms | 0.91 ms | 0.91 ms |
| 50 KB | snapshot + log, truncating | 0.41 KB | 0.10 | 0.22 ms | 0.59 ms | 0.54 ms |
| 500 KB | merged `ydoc` | 296 KB | 138 | 22.9 ms | 4.1 ms | 4.5 ms |
| 500 KB | snapshot + log, 64 rows | 5.0 KB | 3.17 | 0.58 ms | 9.7 ms | 10.1 ms |
| 500 KB | snapshot + log, deleting | 0.66 KB | 1.07 | 0.19 ms | 3.5 ms | 4.0 ms |
| 500 KB | snapshot + log, truncating | 0.55 KB | 0.14 | 0.25 ms | 3.7 ms | 3.9 ms |

What remains: the whole document written once per compaction; for a small
document, the fixed cost of the extra SQL in a join; and for a returning
client, a decode of the snapshot to diff it. Times below a millisecond vary
by about 0.1 ms between runs.

The fold tracking is transaction ids, which only mean something in the
cluster that assigned them. Record the cluster's system identifier
(`pg_control_system()`) with the log, refuse to compact or rotate on a
cluster with another one (after a logical-replication cutover), and adopt
the log there by giving every row the current transaction id and clearing
every folded snapshot. A physical replica keeps the identifier.

```sql
CREATE TABLE doc_snapshots (
  id bigint PRIMARY KEY,
  body ydoc NOT NULL DEFAULT ydoc(),
  state_vector bytea GENERATED ALWAYS AS (ydoc_state_vector(body, gapless => true)) STORED,
  folded pg_snapshot
);
CREATE TABLE doc_updates (
  doc_id bigint NOT NULL,
  txid xid8 NOT NULL DEFAULT pg_current_xact_id(),
  slot smallint NOT NULL,
  update bytea NOT NULL
) PARTITION BY LIST (slot);
CREATE TABLE doc_updates_0 PARTITION OF doc_updates FOR VALUES IN (0);
CREATE TABLE doc_updates_1 PARTITION OF doc_updates FOR VALUES IN (1);
CREATE INDEX ON doc_updates (doc_id, txid);
CREATE TABLE doc_updates_slot (slot smallint NOT NULL);
INSERT INTO doc_updates_slot VALUES (0);

-- Rows of snapshot s not folded into it yet. The txid bound lets the index
-- skip folded rows waiting for their partition's truncate.
--   u.doc_id = s.id AND u.txid >= coalesce(pg_snapshot_xmin(s.folded), '0')
--   AND (s.folded IS NULL OR NOT pg_visible_in_snapshot(u.txid, s.folded))
-- written UNFOLDED below.

-- Write: append to the current partition, and now and then check whether
-- the unfolded log is due for compaction.
INSERT INTO doc_updates (doc_id, slot, update) VALUES ($1, (SELECT slot FROM doc_updates_slot), $2);

-- Compact: fold the unfolded log into the snapshot and record what was seen.
-- Rows past a gap are written again, unfolded, so the snapshot keeps none.
WITH s AS (SELECT * FROM doc_snapshots s WHERE s.id = $1 FOR UPDATE),
log AS (SELECT u.update FROM s JOIN doc_updates u ON UNFOLDED),
reach AS (SELECT ydoc_state_vector(ydoc_apply(s.body, (SELECT ydoc_merge_agg(update) FROM log)::bytea)) AS sv FROM s),
split AS (SELECT update, ydoc_fits(update, (SELECT sv FROM reach)) AS fits FROM log),
done AS (
  UPDATE doc_snapshots t
     SET body = ydoc_apply(s.body, (SELECT ydoc_merge_agg(update) FROM split WHERE fits)::bytea),
         folded = FOLDED  -- pg_current_snapshot() with this transaction's own id still running
    FROM s WHERE t.id = s.id RETURNING t.id
)
INSERT INTO doc_updates (doc_id, slot, update)
  SELECT done.id, (SELECT slot FROM doc_updates_slot), split.update FROM done, split WHERE NOT split.fits;

-- Rotate (own transaction; old is the slot not current, cur the current):
BEGIN;
SET LOCAL lock_timeout = '50ms';
LOCK TABLE doc_updates_<old> IN ACCESS EXCLUSIVE MODE;  -- waits out its writers
INSERT INTO doc_updates (doc_id, txid, slot, update)
  SELECT u.doc_id, u.txid, <cur>, u.update FROM doc_updates_<old> u JOIN doc_snapshots s ON UNFOLDED;
TRUNCATE doc_updates_<old>;
UPDATE doc_updates_slot SET slot = <old>;
COMMIT;

-- Sync step 1: the server's state vector.
SELECT CASE WHEN s.state_vector IS NOT NULL
            THEN ydoc_extend_state_vector(s.state_vector,
                   (SELECT ydoc_merge_agg(u.update) FROM doc_updates u WHERE UNFOLDED))
            ELSE ydoc_state_vector(ydoc_merge(s.body, coalesce(
                   (SELECT ydoc_merge_agg(u.update) FROM doc_updates u WHERE UNFOLDED), ydoc()))) END
  FROM doc_snapshots s WHERE s.id = $1;

-- Sync step 2 for a client at $2: the snapshot's part, then the log's part.
SELECT ydoc_diff(s.body, $2, true),
       (SELECT ydoc_diff(ydoc_merge_agg(u.update), $2, true) FROM doc_updates u WHERE UNFOLDED)
  FROM doc_snapshots s WHERE s.id = $1 AND s.state_vector IS NOT NULL;
-- (No row: the snapshot has a gap; serve ydoc_diff of the merged document.)
```

Rows written again carry the compacting transaction's id. Postgres counts a
transaction's own id as visible in its snapshot once a later transaction has
committed, so the folded snapshot lists it as still running; otherwise a
compaction inside a longer transaction would mark its own copies folded.
yrby-core's `compaction::plan` also keeps the snapshot gap-free, but prunes
content past a gap by re-encoding and deletes the rows, which dropped
content on the out-of-order fixtures; here nothing is pruned or deleted,
and the fixtures pass through the store (`test/pg_document_test.rb`).

To skip writes that change nothing, guard with `ydoc_adds`, or add Postgres's
`suppress_redundant_updates_trigger()` to a merged-`ydoc` table.

## Building and testing

Needs Rust and `cargo-pgrx` 0.19.3 (`cargo install --locked cargo-pgrx --version 0.19.3`,
then `cargo pgrx init --pg17 $(brew --prefix postgresql@17)/bin/pg_config`).

```sh
cargo pgrx test pg17                 # pgrx tests
cargo pgrx install --release         # into the pg_config's Postgres
cargo pgrx start pg17                # or run the pgrx test instance on :28817
cd tests/js && npm install
npm run converge                     # JS Yjs convergence (ROUNDS, PEERS, STEPS, SEED)
npm run concurrency                  # many connections writing one document (WRITERS)
npm run dump                         # pg_dump, pg_restore and binary COPY round trips
npm run bench:storage                # the storage table above (SIZES, EDITS, RATIO, MIN_LOG, ROTATE_EVERY)
```

The convergence test makes random concurrent edits in several JS Yjs docs
(text with surrogate pairs, maps, arrays, partial syncs), sends every update to
Postgres shuffled with some duplicated, and checks `ydoc_apply`,
`ydoc_merge_agg`, snapshot + log with random compactions, the state vector, and
`ydoc_diff` against the JS result.

The concurrency test splits each session's updates across many connections
writing the same document at once, through a merged `ydoc` row, a snapshot +
log that deletes what it folds, and a snapshot + insert-only log in two
partitions, while another connection compacts both logs in a loop, another
rotates the partitioned one, and another reads them. Every store must end
equal to the JS peers, and no read may see the state vector go backwards.
Rotating without carrying unfolded rows forward, or without the lock, fails
it. Under the default READ COMMITTED,
`UPDATE ... SET body = ydoc_apply(body, $1)` re-reads the row after waiting
on another writer's lock, so no update is lost.

The dump test restores every kind of document (empty, NULL, XML, pending, a
TOASTed 200 KB text) through plain and custom `pg_dump` and binary `COPY`,
and checks they come back byte for byte. Binary input is validated like text
input.

On macOS, release builds set `strip = false`: the default strip leaves a dylib
that dyld rejects ("mis-aligned LINKEDIT string pool").
