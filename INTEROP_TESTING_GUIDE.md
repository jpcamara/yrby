# Interop Testing Pattern for Cross-Language Protocol Implementations

This document describes the interop testing pattern used in yrb-lite to validate compatibility between Ruby bindings (via Rust/Magnus), JavaScript (Y.js), and Rust (yrs) implementations of the y-crdt protocol. This pattern can be applied to any project that needs to verify cross-language compatibility.

## Overview

The goal is to ensure that your Ruby implementation can correctly communicate with reference implementations in other languages. This is critical for protocol implementations where binary compatibility matters.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Ruby Test Harness                           │
│                   (test/interop_test.rb)                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │  Ruby Gem   │◄──►│ JS Generator│◄──►│Rust Generator│        │
│  │ (yrb-lite)  │    │   (bun)     │    │  (binary)   │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│                                                                 │
│  Data flows as base64-encoded binary via JSON over stdout      │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. JavaScript Fixture Generator

**Location**: `test/fixtures/yjs_generator.mjs`

A standalone JavaScript file that can be run with bun (or node) to perform operations using the reference JavaScript implementation. It:

- Accepts commands via CLI arguments
- Returns JSON to stdout with base64-encoded binary data
- Provides commands for: creating docs, applying updates, merging, diffing, reading content

**Key design decisions**:
- Use a high default client ID (999999) for `apply-update` to avoid conflicts with updates being applied
- Redirect library warnings to stderr so they don't corrupt JSON output
- Return all binary data as base64 strings in JSON

```javascript
#!/usr/bin/env node
import * as Y from 'yjs'

// Suppress library warnings by redirecting to stderr
const originalLog = console.log
const originalWarn = console.warn
console.log = (...args) => {
  if (args[0]?.toString().includes('[yjs]')) {
    console.error(...args)
  } else {
    originalLog(...args)
  }
}
console.warn = console.error

function toBase64(uint8Array) {
  return Buffer.from(uint8Array).toString('base64')
}

function fromBase64(base64) {
  return new Uint8Array(Buffer.from(base64, 'base64'))
}

const commands = {
  'create-doc': (clientId, fieldName, content) => {
    const doc = new Y.Doc()
    doc.clientID = parseInt(clientId)
    const text = doc.getText(fieldName)
    text.insert(0, content)

    return JSON.stringify({
      update: toBase64(Y.encodeStateAsUpdate(doc)),
      state_vector: toBase64(Y.encodeStateVector(doc)),
      client_id: doc.clientID
    })
  },

  'apply-update': (base64Update, clientId = '999999') => {
    const doc = new Y.Doc()
    doc.clientID = parseInt(clientId)
    Y.applyUpdate(doc, fromBase64(base64Update))

    return JSON.stringify({
      update: toBase64(Y.encodeStateAsUpdate(doc)),
      state_vector: toBase64(Y.encodeStateVector(doc)),
      client_id: doc.clientID
    })
  },

  'get-text': (base64Update, fieldName) => {
    const doc = new Y.Doc()
    Y.applyUpdate(doc, fromBase64(base64Update))
    const text = doc.getText(fieldName)

    return JSON.stringify({
      content: text.toString(),
      length: text.length
    })
  },

  // ... more commands
}

const [command, ...args] = process.argv.slice(2)
console.log(commands[command](...args))
```

### 2. Rust Fixture Generator

**Location**: `test/fixtures/yrs_generator/`

A standalone Rust binary that mirrors the JavaScript generator's functionality. This validates that your Ruby bindings produce output identical to the native Rust library.

**Structure**:
```
test/fixtures/yrs_generator/
├── Cargo.toml
└── src/
    └── main.rs
```

**Important Cargo.toml settings**:
```toml
[package]
name = "yrs_generator"
version = "0.1.0"
edition = "2021"

# CRITICAL: Add empty workspace to prevent cargo from looking for parent workspace
[workspace]

[[bin]]
name = "yrs_generator"
path = "src/main.rs"

[dependencies]
yrs = { version = "0.21", features = ["sync"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
base64 = "0.22"
```

The empty `[workspace]` declaration is essential - it prevents cargo from trying to include this in a parent workspace, which would cause conflicts.

### 3. Ruby Test Harness

**Location**: `test/interop_test.rb`

The test harness that orchestrates all three implementations:

```ruby
require "test_helper"
require "json"
require "open3"

class InteropTest < Minitest::Test
  BUN_PATH = File.expand_path("~/.bun/bin/bun")
  YJS_GENERATOR = File.expand_path("fixtures/yjs_generator.mjs", __dir__)
  YRS_GENERATOR_DIR = File.expand_path("fixtures/yrs_generator", __dir__)
  YRS_GENERATOR = File.join(YRS_GENERATOR_DIR, "target/release/yrs_generator")

  def setup
    # FAIL if tools aren't available - don't silently skip
    unless File.exist?(BUN_PATH)
      raise "bun is required for interop tests. Install with: curl -fsSL https://bun.sh/install | bash"
    end

    unless File.exist?(YRS_GENERATOR)
      if File.exist?(File.join(YRS_GENERATOR_DIR, "Cargo.toml"))
        system("cd #{YRS_GENERATOR_DIR} && cargo build --release 2>/dev/null")
      end

      unless File.exist?(YRS_GENERATOR)
        raise "yrs_generator is required. Build with: cd #{YRS_GENERATOR_DIR} && cargo build --release"
      end
    end
  end

  # Helper to call JavaScript generator
  def yjs(*args)
    stdout, stderr, status = Open3.capture3(BUN_PATH, "run", YJS_GENERATOR, *args.map(&:to_s))
    raise "yjs_generator failed: #{stderr}" unless status.success?
    JSON.parse(stdout)
  end

  # Helper to call Rust generator
  def yrs(*args)
    stdout, status = Open3.capture2(YRS_GENERATOR, *args.map(&:to_s))
    raise "yrs_generator failed: #{stdout}" unless status.success?
    JSON.parse(stdout)
  end

  # Base64 helpers - use pack/unpack, NOT Base64 module (removed in Ruby 3.4)
  def b64_decode(str)
    str.unpack1("m0")
  end

  def b64_encode(str)
    [str].pack("m0")
  end
end
```

## Test Categories

### 1. Inbound Tests (External → Ruby)

Verify your Ruby implementation can consume data from other implementations:

```ruby
def test_yjs_update_applied_to_ruby
  result = yjs("create-doc", 1, "content", "hello from yjs")

  doc = YourGem::Doc.new
  doc.apply_update(b64_decode(result["update"]))

  # Verify state vector sizes match (byte order may differ between implementations)
  assert_equal b64_decode(result["state_vector"]).bytesize, doc.encode_state_vector.bytesize
end

def test_yrs_update_applied_to_ruby
  result = yrs("create-doc", 1, "content", "hello from yrs")

  doc = YourGem::Doc.new
  doc.apply_update(b64_decode(result["update"]))

  # Rust implementations should match exactly
  assert_equal b64_decode(result["state_vector"]), doc.encode_state_vector
end
```

### 2. Outbound Tests (Ruby → External)

Verify other implementations can consume data from your Ruby implementation:

```ruby
def test_ruby_update_applied_to_yjs
  # Create data using external tool, load into Ruby, export, verify external can read
  yjs_doc = yjs("create-doc", 1, "content", "test content")

  doc = YourGem::Doc.new
  doc.apply_update(b64_decode(yjs_doc["update"]))

  update = b64_encode(doc.encode_state_as_update)

  # Verify JavaScript can apply our update
  result = yjs("apply-update", update)
  assert result["state_vector"]

  # Verify content is preserved
  text_result = yjs("get-text", update, "content")
  assert_equal "test content", text_result["content"]
end
```

### 3. Round-Trip Tests (External → Ruby → External)

The most important tests - verify data survives a round trip:

```ruby
def test_yjs_to_yrs_via_ruby
  # Create in JavaScript
  yjs_doc = yjs("create-doc", 1, "content", "cross-platform test")

  # Load into Ruby
  doc = YourGem::Doc.new
  doc.apply_update(b64_decode(yjs_doc["update"]))

  # Export and verify Rust can read it
  update = b64_encode(doc.encode_state_as_update)
  yrs_result = yrs("get-text", update, "content")

  assert_equal "cross-platform test", yrs_result["content"]
end
```

### 4. Protocol/Sync Tests

If your implementation includes sync protocols, test the full exchange:

```ruby
def test_sync_protocol
  # External has content
  external_doc = yjs("create-doc", 1, "content", "sync test")

  # Ruby is empty
  doc = YourGem::Doc.new

  # Ruby sends state vector
  sv = b64_encode(doc.encode_state_vector)

  # External computes diff
  diff = yjs("diff-update", external_doc["update"], sv)

  # Ruby applies diff
  doc.apply_update(b64_decode(diff["diff_update"]))

  # Verify Ruby now has the content
  update = b64_encode(doc.encode_state_as_update)
  text = yjs("get-text", update, "content")
  assert_equal "sync test", text["content"]
end
```

## Key Lessons Learned

### 1. Always Fail, Never Skip

Tests should **fail** if external tools aren't available, not skip. Otherwise CI might silently pass without running critical tests:

```ruby
# BAD - tests silently pass
def setup
  @skip_yjs = !File.exist?(BUN_PATH)
end

def test_something
  skip "bun not available" if @skip_yjs  # Dangerous!
end

# GOOD - tests fail loudly
def setup
  unless File.exist?(BUN_PATH)
    raise "bun is required. Install with: curl -fsSL https://bun.sh/install | bash"
  end
end
```

### 2. Handle Library Warnings

Libraries often log to stdout, which corrupts JSON output. Redirect warnings to stderr:

```javascript
// JavaScript
console.warn = console.error
console.log = (...args) => {
  if (args[0]?.includes('[libname]')) {
    console.error(...args)
  } else {
    originalLog(...args)
  }
}
```

### 3. Avoid Client ID Conflicts

When applying an update to a new document, use a different client ID than the one that created the update:

```javascript
// BAD - causes warnings/errors
'apply-update': (update, clientId = '1') => { ... }

// GOOD - avoids conflicts
'apply-update': (update, clientId = '999999') => { ... }
```

### 4. Use Pack/Unpack for Base64

Ruby 3.4 removed the `base64` gem from default gems. Use pack/unpack instead:

```ruby
# BAD - requires adding base64 to Gemfile
require "base64"
Base64.decode64(str)

# GOOD - works everywhere
str.unpack1("m0")  # decode
[str].pack("m0")   # encode
```

### 5. Byte Order vs. Semantic Equality

Different implementations may encode the same data in different byte orders. Test appropriately:

```ruby
# Between Rust implementations - should match exactly
assert_equal yrs_bytes, ruby_bytes

# Between different languages - test semantic equality
assert_equal yrs_bytes.bytesize, ruby_bytes.bytesize
# Or decode and compare the actual content
```

### 6. Isolate Rust Workspaces

If your main project is a Rust workspace, the generator must be isolated:

```toml
# test/fixtures/yrs_generator/Cargo.toml
[package]
name = "yrs_generator"

[workspace]  # Empty! Prevents inheritance from parent
```

## Applying to AnyCable

For AnyCable, you would create similar generators for:

1. **JavaScript generator** - Using the AnyCable JavaScript client
2. **Go generator** - Using the reference Go implementation
3. **Ruby test harness** - Testing AnyCable-Rails against both

Example commands for an AnyCable generator:
- `encode-message <type> <payload>` - Encode a protocol message
- `decode-message <base64>` - Decode and return message fields
- `create-subscription <channel> <params>` - Create subscription request
- `confirm-subscription <identifier>` - Create confirmation response
- `broadcast <data>` - Create broadcast message
- `ping` / `pong` - Create ping/pong messages

The pattern remains the same:
1. Create external generators that output JSON with base64-encoded binary
2. Write Ruby tests that orchestrate all implementations
3. Verify data can flow in all directions
4. Test full protocol exchanges, not just individual messages

## File Structure Summary

```
your-project/
├── test/
│   ├── interop_test.rb           # Ruby test harness
│   └── fixtures/
│       ├── js_generator.mjs      # JavaScript generator (run with bun/node)
│       └── rust_generator/       # Rust generator (standalone crate)
│           ├── Cargo.toml
│           └── src/
│               └── main.rs
```

## Running Tests

```bash
# Full test suite (includes interop tests)
bundle exec rake test

# Just interop tests
bundle exec rake test TEST=test/interop_test.rb

# Build Rust generator manually if needed
cd test/fixtures/rust_generator && cargo build --release
```
