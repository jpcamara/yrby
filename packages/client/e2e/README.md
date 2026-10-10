# End-to-end: Rust backends

These drive the real `yrby-client` (a `DocumentSessionStore` over
`@anycable/web`, on real WebSockets) through a real `anycable-go`, against yrby's
Rust backends. Each script boots its servers, runs its scenarios, and tears
everything down.

| Script | Backend | Covers |
|---|---|---|
| `anycable_rust.mjs` | `crates/yrby-anycable`'s demo | sync and acknowledgments, presence as whispers, nothing relayed before it is stored, a failed store retried, offline edits across an anycable-go restart, grant refresh and rejection |
| `loco.mjs` | `examples/loco-demo`, serving ActionCable itself, or behind anycable-go with `E2E_TRANSPORT=anycable` | connection identity (the login token, the cookie, AnyCable tokens, refusal), per-user policy, storage and per-attribute encryption checked on disk, compaction, a restart of the app, grants from the crate's grant route |

Both need cargo, and `anycable_rust.mjs` and `E2E_TRANSPORT=anycable` need
`anycable-go` (1.6) on `PATH`. `loco.mjs` also needs
`sqlite3`, or a Postgres for `E2E_DB=postgres` (see the top of the file).
Build the client first:

```sh
npm run build
node e2e/anycable_rust.mjs
node e2e/loco.mjs
E2E_DB=postgres node e2e/loco.mjs
E2E_TRANSPORT=anycable node e2e/loco.mjs
```

`VERBOSE=1` prints every process's output.
