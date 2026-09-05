# Getting started

yrby makes Rails a Yjs backend. It binds
[y-crdt](https://github.com/y-crdt/y-crdt), the Rust engine behind Y.js, into
Ruby, and builds the rest of the stack on top of it: a sync server for Action
Cable and AnyCable, a browser provider, and server-side reading and rendering
of the documents. You get real-time collaboration in a Rails app with no Node
process to run.

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

Ruby 3.4 or newer. Releases include precompiled gems for Ruby 3.4 and 4.0 on
the supported platforms, and the release workflow smoke-tests the native builds
on Linux x86_64 and macOS arm64. If a precompiled gem matches your platform you
don't need Rust. A source build needs [Rust](https://rustup.rs).

## Install the storage

The generator adds the migration. The models and the channel are already in the
gem, the same way Action Text owns `ActionText::RichText`.

```bash
bin/rails yrby:install
bin/rails db:migrate
```

## The server side

You don't write one. Render the collaborative document in a view where the page
is already allowed to edit the record:

```erb
<%= collaborative_document_tag @post, :body %>
```

The tag renders a signed grant for that record and attribute, the same way
`turbo_stream_from` signs its stream names. The gem's `Y::DocumentChannel`
verifies the grant when a client subscribes, and it records every change as
`Y::Document` rows before it acknowledges the change. The client only ever
sends the grant. A grant that is missing, tampered with, or minted
for a different attribute is rejected, and so is one whose record has since
been deleted. The authorization check is the one your controller already made
when it decided to render the page. The grant is how the channel knows that
check happened.

The document is rows in your database, and you can read it back in Ruby:

```ruby
doc = Y::Doc.new
doc.apply_update(Y::Document.for(@post, :body).load_state)
doc.read_text("content")  # or Y::Lexxy.new(doc).to_html for rich text
```

If you need custom storage, documents keyed by room instead of by record, or
your own authorization scheme, you write a channel yourself. It uses the same
concern `Y::DocumentChannel` does and takes a few lines.
[The document channel](/docs/document-channel) covers it.

## The browser side

The tag renders an element that connects on its own, like the one
`turbo_stream_from` renders. Import it once. When the document has synced, your
code gets it and hands it to whichever editor binding you use:

```js
import "yrby-client/element"

document.querySelector("yrby-document").addEventListener("yrby:synced", ({ target }) => {
  bindYourEditor(target.doc) // any Yjs editor binding
})
```

`yrby:synced` fires after the first catch-up with the server. Bind the editor
there. Most editor bindings seed an empty document when they mount, so if you
bind before the server's state arrives, each client inserts its own top-level
node and they fight over it. On AnyCable, set the shared consumer once before
the elements connect: `YrbyDocumentElement.consumer = createCable()`. See
[The JavaScript client](/docs/javascript-client).

## What yrby covers

`yrby` binds the part of `y-crdt` you need to sync and persist collaborative
documents: a `Doc`, awareness, and the y-websocket protocol primitives. By
default the Ruby side treats a document as opaque CRDT state. It applies
updates, answers sync handshakes, and records deltas without looking at the
contents. The browser editor decides what shape the document has. When you do
need to look inside, `Doc#read_text` and `Doc#read_map` rebuild it in Ruby.

The API is small. Most of the work went into durability, resiliency, delivery
guarantees, correctness, and thread safety.

## Editors

yrby syncs opaque Yjs updates, so any editor with a Yjs binding works. The demo
app runs four of them, and CI drives each one in a real Chrome.

| Editor | Yjs binding |
|---|---|
| [Tiptap](https://tiptap.dev) (v2) | `@tiptap/extension-collaboration` |
| [Lexxy](https://github.com/basecamp/lexxy) (Lexical) | [`lexxy-realtime`](https://www.npmjs.com/package/lexxy-realtime) |
| [Rhino Editor](https://github.com/KonnorRogers/rhino-editor) (Tiptap 3) | `@tiptap/extension-collaboration` + `-caret` |
| [CodeMirror 6](https://codemirror.net) | `y-codemirror.next` |

The same channel also syncs plain Yjs shapes with no editor: a whiteboard on a
`Y.Map`, a kanban board on a `Y.Array`, a spreadsheet on a `Y.Array` of nested
`Y.Map`s. The [demos](/demos) on this site run six live. One of them is a Lexxy
editor on the published
[lexxy-realtime](https://github.com/jpcamara/lexxy-realtime) stack, where the
server renders the document into a plain column with `Y::Lexxy` as you type.

## Reading a document in Ruby

Rebuild a document on the server for search, exports, or emails. This runs in
Ruby, with no Node process:

```ruby
doc.read_text("prosemirror")  # => plain text of a Y.Text root, or nil
doc.read_xml("root")          # => text of an XML root, one block per line
doc.read_map("state")         # => a Y.Map root as a JSON string
doc.read_array("cards")       # => a Y.Array root as a JSON string
```

For HTML that matches the editor's own serializer byte for byte, see
[Server-side rendering](/docs/rendering).

## Thread safety

A `Doc` can be shared across Ruby threads. Puma workers, Action Cable
connection threads, and background jobs can all use the same one at once, with
no locking on your side.

Every method that does real CRDT work releases Ruby's Global VM Lock while the
native code runs. So CRDT work runs in parallel across Ruby threads on MRI, and
a thread applying a large update doesn't stall the VM.
