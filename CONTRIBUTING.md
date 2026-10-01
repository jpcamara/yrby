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

### Browser tests for the document element

After `bundle install` and `bundle exec rake compile`, run:

```bash
cd packages/client
npm ci
npm test
npm run test:browser
npm run test:browser:turbolinks
npm run test:browser:collaboration
```

`npm ci` installs `agent-browser`, which also needs a Chrome to drive. Run
`agent-browser install` once, or set `AGENT_BROWSER_EXECUTABLE_PATH` to an
existing Chrome. Set `AB_BIN` to use a different `agent-browser` binary.
`PORT` defaults to 3789. Each run starts a Rails/SQLite/Puma fixture app and
drives two Chrome sessions through real ActionCable, the AnyCable web client,
and Turbo navigation. It checks pending-edit recovery, shared views,
retargeting, presence, async startup, encrypted storage, subscribe-time
authorization, and late callbacks from replaced subscriptions. When it
finishes, it shuts down its server and browser sessions and writes logs and a
screenshot under `tmp/`.

The collaboration suite runs four independent Chrome sessions for each
combination of Turbo or Turbolinks with the ActionCable or AnyCable
JavaScript consumer, all against the fixture's real Rails ActionCable
endpoint. Typing continues through page visits, delayed acknowledgments,
two-client outages, history restores, and held cached previews. The suite
checks exact character counts, editor/server convergence, fresh-client
recovery, binding lifetimes, and cleanup after awareness callbacks throw.
The fixture applies textarea edits incrementally, so typing preserves other
users' character identities.

Set `FRAMEWORK=turbo` or `FRAMEWORK=turbolinks` to pick a framework, and
`CONSUMER=actioncable` or `CONSUMER=anycable` to pick a consumer. Ports start
at `PORT` (default 3793). The combinations run one after another, each with
four browser sessions plus a fresh reader. JSON evidence, server logs, and
screenshots go to `tmp/browser-collaboration/<run>/<framework-consumer>/`,
and CI uploads them. Run the browser suites one at a time so their browser
daemons don't interfere with each other.

The fixture has no authentication beyond the grants under test, so only run
it locally.

### Submission checks

- Keep the binding layer thin; put testable logic in pure functions.
- Add/adjust tests (Ruby, and Rust for pure logic).
- Make sure `rake test`, `cargo test`, rubocop, clippy, and rustfmt all pass.
- Update `CHANGELOG.md` under **[Unreleased]**.
