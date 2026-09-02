# Getting started

yrby makes Rails a real Yjs backend. It binds
[y-crdt](https://github.com/y-crdt/y-crdt), the Rust engine behind Y.js, into
Ruby, and builds the rest of the stack around it: a sync server for Action Cable
and AnyCable, a browser provider, and server-side reading and rendering of the
documents. Real-time collaboration in a Rails app with no Node process anywhere
in the path.

## Install

Two gems and one npm package.

```ruby
# Core CRDT + protocol primitives:
gem "yrby"

# The Rails side (the sync channel, document models, the generator).
# Formerly yrby-actioncable; that name stops at 0.3.1.
gem "yrby-rails"
```

```
npm install yrby-client
```

Ruby 3.4 or newer. The release workflow builds precompiled gems for Ruby 3.4 and
4.0 across the supported platforms, with native smoke tests on Linux x86_64 and
macOS arm64. Installing a matching platform gem needs no Rust; a source build
needs [Rust](https://rustup.rs).

## Install the storage

One generator lands the migration. The models and the channel ship in the
gem, the way Action Text owns `ActionText::RichText`.

```bash
bin/rails yrby:install
bin/rails db:migrate
```

## The server side

There isn't one to write. Render a collaborative document where the page is
already authorized to edit the record:

```erb
<%= collaborative_document_tag @post, :body %>
```

The tag renders a signed grant for exactly that record and attribute — the
way `turbo_stream_from` signs its stream names. The gem's own
`Y::DocumentChannel` verifies the grant on subscribe and records every
change as `Y::Document` rows before acknowledging it. Clients never name
documents: a missing, tampered, or wrong-attribute grant is rejected, and so
is one whose record no longer exists. Authorization happened when your
controller decided to render the tag; the grant carries that decision to the
socket.

And the document is rows in your database, readable without a browser:

```ruby
doc = Y::Doc.new
doc.apply_update(Y::Document.for(@post, :body).load_state)
doc.read_text("content")  # or Y::Lexxy.new(doc).to_html for rich text
```

Custom storage, room-keyed documents, or your own authorization scheme mean
writing a channel with the same concern `Y::DocumentChannel` uses — a few
lines, covered in [The document channel](/docs/document-channel).

## The browser side

`yrby-client`'s `ActionCableProvider` connects anything that speaks Yjs. The
tag carries everything the client needs as data attributes.

```js
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const el = document.querySelector("[data-collaborative-document]")
const ydoc = new Y.Doc()
const provider = new ActionCableProvider(ydoc, createConsumer(),
  el.dataset.channel, { grant: el.dataset.grant, name: el.dataset.name })
provider.connect()

await provider.whenSynced
// now hand ydoc to an editor binding
```

Bind after the first sync, not before. Most editor bindings seed an empty
document when they mount, so binding early makes each client insert its own
competing top-level node. See [The JavaScript client](/docs/javascript-client).

## What yrby covers

`yrby` binds just the part of `y-crdt` you need to sync and persist
collaborative documents: a `Doc`, awareness, and the y-websocket protocol
primitives. By default the Ruby side treats a document as opaque CRDT state. It
applies updates, answers sync handshakes, and records deltas without reaching
into the contents; the browser editor owns the document's shape. When you do
need to look inside, `Doc#read_text` and `Doc#read_map` reconstruct it
server-side, in Ruby.

The surface is small on purpose. The focus is durability, resiliency, delivery
guarantees, correctness, and thread safety.

## Editors

yrby syncs opaque Yjs updates, so it works with any editor that has a Yjs
binding. The demo app runs four, and CI drives each one in real Chrome.

| Editor | Yjs binding |
|---|---|
| [Tiptap](https://tiptap.dev) (v2) | `@tiptap/extension-collaboration` |
| [Lexxy](https://github.com/basecamp/lexxy) (Lexical) | [`lexxy-realtime`](https://www.npmjs.com/package/lexxy-realtime) |
| [Rhino Editor](https://github.com/KonnorRogers/rhino-editor) (Tiptap 3) | `@tiptap/extension-collaboration` + `-caret` |
| [CodeMirror 6](https://codemirror.net) | `y-codemirror.next` |

The same channel also syncs plain Yjs shapes with no editor at all: a whiteboard
on a `Y.Map`, a kanban board on a `Y.Array`, a spreadsheet on a `Y.Array` of
nested `Y.Map`s. The [demos](/demos) on this site run six of those live —
including a Lexxy editor on the published
[lexxy-realtime](https://github.com/jpcamara/lexxy-realtime) stack, with the
server rendering the document into a plain column via `Y::Lexxy` as you type.

## Reading a document in Ruby

Reconstruct a document server-side for search, exports, or emails, with no Node
process:

```ruby
doc.read_text("prosemirror")  # => plain text of a Y.Text root, or nil
doc.read_xml("root")          # => text of an XML root, one block per line
doc.read_map("state")         # => a Y.Map root as a JSON string
```

For HTML that matches an editor's own serializer byte for byte, see
[Server-side rendering](/docs/rendering).

## Thread safety

A `Doc` is safe to share across Ruby threads, used concurrently from Puma
workers, Action Cable connection threads, or background jobs without external
locking.

Every method that does real CRDT work releases Ruby's Global VM Lock while the
native code runs. CRDT work parallelizes across Ruby threads on MRI, and a
thread applying a large update can't stall the VM.
