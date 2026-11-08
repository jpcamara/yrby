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
existing Chrome. Set `AB_BIN` to use a different `agent-browser` binary. Each
suite starts a local Rails fixture app (`test/browser/app.rb`) on `PORT`
(default 3789; the collaboration suite starts at 3793) and writes logs and
screenshots under `tmp/`.

The collaboration suite runs every combination of Turbo or Turbolinks with the
ActionCable or AnyCable client. Set `FRAMEWORK=turbo` or `FRAMEWORK=turbolinks`
and `CONSUMER=actioncable` or `CONSUMER=anycable` to run just one. Run the
browser suites one at a time so their browser daemons don't interfere with
each other.

The fixture has no authentication beyond the grants under test, so only run
it locally.

### Rage tests

`Y::Rage` is tested against a small Rage app in `test/rage`, which has its own
bundle so Rage never loads into the main suite. After `bundle exec rake
compile`:

```bash
cd test/rage
bundle install
bundle exec ruby y_rage_test.rb   # Y::Rage against real Rage

cd ../../packages/client
npm ci
npm run test:rage
```

`npm run test:rage` starts the app with two workers and drives it with
`ActionCableProvider` clients: concurrent edits converge and are acked,
presence reaches the other client, an update written from Ruby reaches both,
a late joiner loads from storage, and an unauthorized key is rejected. The
server log goes to `tmp/rage-server.log`.

### AnyCable tests

`Y::AnyCable` is tested against a Rage app in `test/anycable` that answers
anycable-go's HTTP RPC. It has its own bundle too. The integration test needs
[anycable-go](https://docs.anycable.io/anycable-go/getting_started) on `PATH`
(`brew install anycable-go`, or a binary from its releases), or its path in
`ANYCABLE_GO`. After `bundle exec rake compile`:

```bash
cd test/anycable
bundle install
bundle exec ruby y_any_cable_test.rb   # Y::AnyCable through anycable-core's RPC handler

cd ../../packages/client
npm ci
npm run test:anycable
```

`npm run test:anycable` starts the app with two workers behind anycable-go
and runs the same checks as `test:rage`, plus a refused connection and
identifiers from both `identify` and a JWT. Logs go to `tmp/anycable-rpc.log`
and `tmp/anycable-go.log`.

`npm run test:anycable:yjs` drives the same app through the `/yjs/` binary
endpoint. That endpoint is only in the Thruster fork at
<https://github.com/jpcamara/thruster>, so set `THRUST` to a build of it. CI
doesn't run this one.

### Submission checks

- Keep the binding layer thin; put testable logic in pure functions.
- Add/adjust tests (Ruby, and Rust for pure logic).
- Make sure `rake test`, `cargo test`, rubocop, clippy, and rustfmt all pass.
- Update `CHANGELOG.md` under **[Unreleased]**.
