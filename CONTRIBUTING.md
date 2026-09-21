# Contributing to yrby

Issues, bug reports, and PRs are all welcome.

## Prerequisites

- **Ruby** 3.4+
- **Rust** (stable), from <https://rustup.rs>

That's all you need to work on the gem itself. The demo additionally uses
PostgreSQL, [bun](https://bun.sh), and (for some tests) Redis and
[anycable-go](https://docs.anycable.io).

## Building & testing the gem

```bash
bundle install
bundle exec rake compile        # build the Rust extension
bundle exec rake test           # Ruby test suite (test/**/*_test.rb)

cargo test  --manifest-path ext/yrby/Cargo.toml   # Rust unit tests
```

### Linting

CI enforces all of these; run them before opening a PR:

```bash
bundle exec rubocop                                              # Ruby
cargo fmt   --manifest-path ext/yrby/Cargo.toml -- --check   # Rust format
cargo clippy --manifest-path ext/yrby/Cargo.toml --all-targets -- -D warnings
```

`cargo fmt --manifest-path ext/yrby/Cargo.toml` and `bundle exec rubocop -A`
auto-fix most issues.

## Layout

```
lib/                     # Ruby: Y::ActionCable::Sync (the ActionCable concern)
ext/yrby/src/        # Rust: lib.rs (magnus bindings) + protocol.rs (pure protocol helpers)
test/                    # Ruby unit tests
examples/actioncable-demo/   # a separate, deliberately thorough demo app (see below)
```

The native code keeps the binding (magnus/`RString`/GVL) separate from pure
logic (e.g. `classify_message`, `merged_doc_update`) so the logic is
unit-tested directly in Rust.

## The demo

[`examples/actioncable-demo`](examples/actioncable-demo) is its own Rails app
with its own bundle. It covers a lot of ground: classic ActionCable, AnyCable,
a Postgres-backed audit store, and a fairly large end-to-end, load, and
real-browser test suite. It isn't part of the gem's packaged code, so treat it
as documentation by example. Its README covers how to run it and what each test
scenario does.

```bash
cd examples/actioncable-demo
bundle install
bin/rails db:prepare
cd frontend && bun install && bun run build && cd ..
bin/rails s
```

## Pull requests

### Document element browser regression

After `bundle install` and `bundle exec rake compile`, run:

```bash
cd packages/client
npm ci
npm test
npm run test:browser
npm run test:browser:turbolinks
npm run test:browser:collaboration
```

`npm ci` installs `agent-browser`. It also needs a Chrome to drive: run
`agent-browser install` once, or point `AGENT_BROWSER_EXECUTABLE_PATH` at an
existing Chrome. `AB_BIN` selects a different `agent-browser` binary, and
`PORT` defaults to 3789. The run starts a Rails/SQLite/Puma fixture and drives
two Chrome sessions through real ActionCable, the AnyCable web client, and
Turbo navigation. It checks pending-edit recovery, shared views, retargeting,
presence, async startup, encrypted and custom storage, subscribe-time
authorization, and late callbacks from replaced subscriptions. It stops its
server and browser sessions afterward. Logs and a screenshot go under `tmp/`.

The collaboration suite runs four independent Chrome sessions for each pairing
of Turbo/Turbolinks and the ActionCable/AnyCable JavaScript consumers. All use the
fixture's real Rails ActionCable endpoint. Actual keyboard input continues during
page visits, delayed acknowledgments, two-client outages, history restores, and
held cached previews. It checks exact character counts, editor/server convergence,
fresh-client recovery, binding lifetimes, and cleanup after awareness callbacks
throw. The fixture applies incremental textarea edits so typing preserves other
users' character identities.

`FRAMEWORK=turbo` or `FRAMEWORK=turbolinks` selects a framework;
`CONSUMER=actioncable` or `CONSUMER=anycable` selects a consumer. Its port range
starts at `PORT` (default 3793). The combinations run sequentially; each uses four
browser sessions plus a fresh reader. JSON evidence, server logs, and screenshots
are saved under `tmp/browser-collaboration/<run>/<framework-consumer>/` and uploaded
by CI. Run browser suites sequentially so their browser daemons do not interfere.

The fixture is local-only. It has no authentication beyond the grants being
tested. Do not deploy it.

### Submission checks

- Keep the binding layer thin; put testable logic in pure functions.
- Add/adjust tests (Ruby, and Rust for pure logic).
- Make sure `rake test`, `cargo test`, rubocop, clippy, and rustfmt all pass.
- Update `CHANGELOG.md` under **[Unreleased]**.
