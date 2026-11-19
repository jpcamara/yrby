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

Serve a client without decoding the snapshot. Keep its state vector in a
generated column and extend it by the log for sync step 1. For step 2 send
the snapshot's part and the log's part as two updates, snapshot first; a
client with nothing gets the snapshot's bytes as stored. A snapshot holding
content past a gap has no stored state vector (`gapless => true` gives NULL)
and is served merged instead.

Measured on a Mac mini (PG 17, one-character edits, one statement each,
compactions counted, autovacuum off; joins timed with the log halfway to its
next compaction; `tests/js/storage_bench.mjs`). "64 rows" is the same
snapshot + log compacted every 64 rows and served merged:

| Starting doc | Storage | WAL per edit | Dead tuples per edit | Per edit | New client joins | Returning client joins |
|---|---|---|---|---|---|---|
| 2 KB | merged `ydoc` | 1.9 KB | 0.24 | 0.25 ms | 0.23 ms | 0.22 ms |
| 2 KB | snapshot + log, 64 rows | 0.36 KB | 1.03 | 0.22 ms | 0.74 ms | 0.67 ms |
| 2 KB | snapshot + log, by size | 0.34 KB | 1.01 | 0.19 ms | 0.86 ms | 0.83 ms |
| 50 KB | merged `ydoc` | 29.6 KB | 14.1 | 1.98 ms | 0.38 ms | 0.40 ms |
| 50 KB | snapshot + log, 64 rows | 0.79 KB | 1.22 | 0.13 ms | 1.10 ms | 1.10 ms |
| 50 KB | snapshot + log, by size | 0.52 KB | 1.09 | 0.10 ms | 0.54 ms | 0.55 ms |
| 500 KB | merged `ydoc` | 296 KB | 138 | 19.7 ms | 4.3 ms | 4.7 ms |
| 500 KB | snapshot + log, 64 rows | 5.0 KB | 3.17 | 0.61 ms | 10.0 ms | 10.6 ms |
| 500 KB | snapshot + log, by size | 0.66 KB | 1.07 | 0.22 ms | 3.7 ms | 3.3 ms |

What remains: one dead tuple per edit, from deleting log rows at compaction;
the whole document written once per compaction; and, for a small document,
the fixed cost of the extra SQL in a join. A returning client costs a decode
of the snapshot, to diff it.

```sql
CREATE TABLE doc_snapshots (
  id bigint PRIMARY KEY,
  body ydoc NOT NULL DEFAULT ydoc(),
  state_vector bytea GENERATED ALWAYS AS (ydoc_state_vector(body, gapless => true)) STORED
);
CREATE TABLE doc_updates (
  id bigserial PRIMARY KEY,
  doc_id bigint NOT NULL REFERENCES doc_snapshots,
  update bytea NOT NULL
);
CREATE INDEX ON doc_updates (doc_id, id);

-- Write: append, and now and then check whether the log is due.
INSERT INTO doc_updates (doc_id, update) VALUES ($1, $2);
SELECT (SELECT coalesce(sum(octet_length(update)), 0) FROM doc_updates WHERE doc_id = $1)
       >= greatest(4096, 0.1 * (SELECT pg_column_size(body) FROM doc_snapshots WHERE id = $1));

-- Sync step 1: the server's state vector.
SELECT CASE WHEN s.state_vector IS NOT NULL
            THEN ydoc_extend_state_vector(s.state_vector,
                   (SELECT ydoc_merge_agg(update) FROM doc_updates WHERE doc_id = $1))
            ELSE ydoc_state_vector(ydoc_merge(s.body, coalesce(
                   (SELECT ydoc_merge_agg(update) FROM doc_updates WHERE doc_id = $1), ydoc()))) END
  FROM doc_snapshots s WHERE s.id = $1;

-- Sync step 2 for a client at $2: the snapshot's part, then the log's part.
SELECT ydoc_diff(s.body, $2, true),
       (SELECT ydoc_diff(ydoc_merge_agg(update), $2, true) FROM doc_updates WHERE doc_id = $1)
  FROM doc_snapshots s WHERE s.id = $1 AND s.state_vector IS NOT NULL;
-- (No row: the snapshot has a gap; serve ydoc_diff of the merged document.)

-- Read the whole document: snapshot plus log, merged.
SELECT ydoc_merge_agg(part) FROM (
  SELECT body::bytea AS part FROM doc_snapshots WHERE id = $1
  UNION ALL
  SELECT update FROM doc_updates WHERE doc_id = $1
) parts;

-- Compact: fold the log into the snapshot and delete it, in one statement.
WITH folded AS (DELETE FROM doc_updates WHERE doc_id = $1 RETURNING update)
UPDATE doc_snapshots
   SET body = ydoc_apply(body, (SELECT ydoc_merge_agg(update)::bytea FROM folded))
 WHERE id = $1;
```

Compaction deletes every row it folds. An update still waiting on a dependency
waits inside the snapshot, as it would in a merged `ydoc` column, so no row
needs to stay behind. (yrby-core's `compaction::plan` keeps the snapshot
gap-free and leaves such rows in the log instead; with out-of-order rows that
approach can drop content, see the fixtures.)

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
npm run bench:storage                # the storage table above (SIZES, EDITS, RATIO, MIN_LOG)
```

The convergence test makes random concurrent edits in several JS Yjs docs
(text with surrogate pairs, maps, arrays, partial syncs), sends every update to
Postgres shuffled with some duplicated, and checks `ydoc_apply`,
`ydoc_merge_agg`, snapshot + log with random compactions, the state vector, and
`ydoc_diff` against the JS result.

The concurrency test splits each session's updates across many connections
writing the same document at once, through both a merged `ydoc` row and a
snapshot + log, while another connection compacts the log in a loop and
another reads it. Both stores must end equal to the JS peers, and no read may
see the state vector go backwards. Under the default READ COMMITTED,
`UPDATE ... SET body = ydoc_apply(body, $1)` re-reads the row after waiting
on another writer's lock, so no update is lost.

The dump test restores every kind of document (empty, NULL, XML, pending, a
TOASTed 200 KB text) through plain and custom `pg_dump` and binary `COPY`,
and checks they come back byte for byte. Binary input is validated like text
input.

On macOS, release builds set `strip = false`: the default strip leaves a dylib
that dyld rejects ("mis-aligned LINKEDIT string pool").
