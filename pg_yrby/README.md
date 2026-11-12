# pg_yrby

A Postgres extension, in Rust with [pgrx](https://github.com/pgcentralfoundation/pgrx),
that stores [Yjs](https://yjs.dev) documents in a `ydoc` column and runs the
sync operations a Yjs server needs in SQL. Built on
[yrs](https://github.com/y-crdt/y-crdt) 0.28.

```sql
CREATE EXTENSION pg_yrby;
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
| `ydoc_state_vector(ydoc)` | `bytea` | Sync step 1. |
| `ydoc_diff(ydoc, sv bytea = NULL, include_pending bool = false)` | `bytea` | Sync step 2: what a peer with `sv` is missing; the whole document without `sv`. Leaves out pending content unless `include_pending`, which serves it as Yjs's `encodeStateAsUpdate` does, so the peer holds the gap and heals when the missing update reaches it. |
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

To make that hold, pg_yrby combines updates with `merge_updates_v1` whenever
anything is pending, never by applying them one after another to a yrs `Doc`.
The convergence test found that re-encoding a `Doc` that holds pending
content can lose some, and that in yrs 0.27 out-of-order delivery through a
`Doc` could leave content stuck as pending for good (fixed in 0.28.1). JS Yjs
handles the same update orders fine. The failing orders are kept as fixtures in `tests/fixtures/out-of-order`.

## Storage: merged document or snapshot plus log

A `ydoc` column rewrites the whole document on every change. For a document
edited often, keep a snapshot and append updates to a log, and fold the log
into the snapshot now and then. Measured on a Mac mini (PG 17, 1000 edits,
one statement each, `tests/js/storage_bench.mjs`):

| Starting doc | Storage | Per edit | WAL | Table size |
|---|---|---|---|---|
| 2 KB | merged `ydoc` | 0.44 ms | 6.8 MB | 6.1 MB |
| 2 KB | snapshot + log | 0.07 ms | 0.37 MB | 0.28 MB |
| 500 KB | merged `ydoc` | 6.4 ms | 95 MB | 90 MB |
| 500 KB | snapshot + log | 0.10 ms | 0.89 MB | 0.79 MB |

With a 200-row log, a snapshot + log read takes about as long as reading the merged `ydoc`.

```sql
CREATE TABLE doc_snapshots (id bigint PRIMARY KEY, body ydoc NOT NULL DEFAULT ydoc());
CREATE TABLE doc_updates (
  id bigserial PRIMARY KEY,
  doc_id bigint NOT NULL REFERENCES doc_snapshots,
  update bytea NOT NULL
);
CREATE INDEX ON doc_updates (doc_id, id);

-- Write: append (optionally skip updates that add nothing).
INSERT INTO doc_updates (doc_id, update) VALUES ($1, $2);

-- Read: snapshot plus log, merged.
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
npm run bench:storage                # the table above
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
