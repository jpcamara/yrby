# YrbLite

Simple Ruby bindings for y-crdt via Rust, implementing the y-websocket sync protocol.

This gem provides minimal functionality needed to synchronize Y.js documents between clients using ActionCable or similar WebSocket solutions.

## Features

- **Built on yrs**: Uses the official Rust y-crdt implementation
- **Complete sync protocol**: Full y-websocket protocol support via `yrs::sync`
- **Awareness support**: User presence/cursor state management
- **Thread-safe**: Rust's memory safety guarantees
- **ProseMirror extraction**: Read ProseMirror/Tiptap editor content from Y.Doc updates without JavaScript

## Installation

### Prerequisites

- Rust toolchain (install from https://rustup.rs)
- Ruby 3.0+

### Setup

```bash
bundle install
rake compile
```

## Usage

### Doc (Low-Level Document Sync)

```ruby
require "yrb_lite"

# Create docs
doc = YrbLite::Doc.new        # random client ID
doc = YrbLite::Doc.new(12345) # specific client ID

# Get document info
doc.client_id  # => unique client identifier
doc.guid       # => document GUID

# Encoding
doc.encode_state_vector           # => current state vector
doc.encode_state_as_update        # => full update
doc.encode_state_as_update(sv)    # => update diff against state vector

# Applying updates
doc.apply_update(update_bytes)    # apply raw V1 update

# Sync protocol messages
doc.sync_step1                    # => SyncStep1 message (contains state vector)
doc.sync_step2(state_vector)      # => SyncStep2 message (contains update)
doc.handle_sync_message(data)     # => [msg_type, sync_type, response]
doc.encode_update_message(update) # => wrap update as sync Update message
```

### Awareness (Document + Presence)

```ruby
# Create awareness instances (each contains a Doc)
awareness = YrbLite::Awareness.new        # random client ID
awareness = YrbLite::Awareness.new(12345) # specific client ID

# Get document info
awareness.client_id  # => unique client identifier
awareness.guid       # => document GUID
```

### Handling Sync Messages

```ruby
# When connection opens, send initial sync messages
initial_message = awareness.start
# Send initial_message to peer via WebSocket

# When receiving messages from peer
response = awareness.handle(incoming_data)
# Send response back to peer if not empty
send_to_peer(response) unless response.empty?
```

### ActionCable Integration Example

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  def subscribed
    @awareness = find_or_create_awareness(params[:id])
    stream_for @awareness

    # Send initial sync messages to new client
    transmit(data: encode(awareness.start))
  end

  def receive(data)
    message = decode(data["data"])
    response = @awareness.handle(message)

    # Send response if needed
    transmit(data: encode(response)) unless response.empty?

    # Broadcast updates to other clients
    # (you may want to filter based on message type)
    DocumentChannel.broadcast_to(@awareness, data: data["data"])
  end

  private

  def encode(binary) = Base64.strict_encode64(binary)
  def decode(encoded) = Base64.strict_decode64(encoded)
end
```

### User Awareness/Presence

```ruby
# Set local user state (cursor position, name, etc.)
awareness.set_local_state('{"user": {"name": "Alice", "color": "#ff0000"}}')

# Get local state
awareness.local_state  # => '{"user": {"name": "Alice", "color": "#ff0000"}}'

# Clear local state (e.g., when disconnecting)
awareness.clear_local_state

# Encode awareness update for broadcasting
update = awareness.encode_awareness_update
```

### Low-Level Access

```ruby
# Get state vector for manual sync
sv = awareness.encode_state_vector

# Get update diffed against a state vector
update = awareness.encode_state_as_update(remote_state_vector)

# Apply raw update to the document
awareness.apply_update(update_bytes)

# Wrap raw update data in a sync message
message = awareness.encode_update(update_bytes)
```

### ProseMirror Content Extraction

Extract ProseMirror/Tiptap editor content from Y.Doc data without JavaScript.
The conversion runs natively in the Rust extension, reading the same CRDT
structures y-prosemirror reads in the browser:

```ruby
# From a raw binary update
content = YrbLite::ProseMirrorExtractor.extract(update_bytes)
# => {"type" => "doc", "content" => [...]}

# From a Doc
content = YrbLite::ProseMirrorExtractor.extract_from_doc(doc)

# Specify the XML fragment name (defaults to trying "prosemirror", "default", "doc")
content = YrbLite::ProseMirrorExtractor.extract(update_bytes, fragment: "prosemirror")
```

See [docs/PROSEMIRROR.md](docs/PROSEMIRROR.md) and [docs/ACCURACY.md](docs/ACCURACY.md)
for the research behind the ProseMirror <-> Y.Doc mapping.

## Message Type Constants

```ruby
YrbLite::MSG_SYNC            # 0 - Document sync messages
YrbLite::MSG_AWARENESS       # 1 - User presence data
YrbLite::MSG_AUTH            # 2 - Authentication
YrbLite::MSG_QUERY_AWARENESS # 3 - Request awareness state

YrbLite::MSG_SYNC_STEP1      # 0 - State vector request
YrbLite::MSG_SYNC_STEP2      # 1 - Update response
YrbLite::MSG_SYNC_UPDATE     # 2 - Incremental update
```

## Sync Flow

```
Client A                          Server
   |                                  |
   |-------- start() --------------->|
   |  (SyncStep1 + Awareness)        |
   |                                  |
   |<------- handle() response ------|
   |  (SyncStep2)                    |
   |                                  |
   |  (Document synchronized!)        |
   |                                  |
   |<------- updates ----------------|
   |-------- updates --------------->|
```

## Development

```bash
# Setup
bundle install

# Build extension
rake compile

# Run tests
rake test

# Clean build artifacts
rake clean
```

## License

MIT License

## Acknowledgments

- [y-crdt/yrs](https://github.com/y-crdt/y-crdt) - The Rust implementation of Y.js
- [Magnus](https://github.com/matsadler/magnus) - Ruby bindings for Rust
- [rb-sys](https://github.com/oxidize-rb/rb-sys) - Rust extensions for Ruby
