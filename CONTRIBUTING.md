# Contributing to y-ruby

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

cargo test  --manifest-path ext/y_ruby/Cargo.toml   # Rust unit tests
```

### Linting

CI enforces all of these; run them before opening a PR:

```bash
bundle exec rubocop                                              # Ruby
cargo fmt   --manifest-path ext/y_ruby/Cargo.toml -- --check   # Rust format
cargo clippy --manifest-path ext/y_ruby/Cargo.toml --all-targets -- -D warnings
```

`cargo fmt --manifest-path ext/y_ruby/Cargo.toml` and `bundle exec rubocop -A`
auto-fix most issues.

## Layout

```
lib/                     # Ruby: Y::ActionCable::Sync (the ActionCable concern)
ext/y_ruby/src/        # Rust: lib.rs (magnus bindings) + protocol.rs (pure protocol helpers)
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

- Keep the binding layer thin; put testable logic in pure functions.
- Add/adjust tests (Ruby, and Rust for pure logic).
- Make sure `rake test`, `cargo test`, rubocop, clippy, and rustfmt all pass.
- Update `CHANGELOG.md` under **[Unreleased]**.
