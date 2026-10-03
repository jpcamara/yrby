# Getting started

yrby makes Rails a Yjs backend. It binds
[y-crdt](https://github.com/y-crdt/y-crdt), the Rust engine behind Y.js, into
Ruby. On top of that it builds a sync server for Action Cable and AnyCable, a
browser provider, and server-side reading and rendering of the documents. You
get real-time collaboration in a Rails app with no Node process to run.

## Install

Add both gems, then install the browser package and its peer dependencies:

```ruby
# Core CRDT and protocol primitives
gem "yrby"

# The Rails side: the sync channel, the document models, the generator
gem "yrby-rails"
```

```
npm install yrby-client yjs y-protocols @rails/actioncable
```

yrby needs Ruby 3.4 or newer. Releases include precompiled gems for Ruby 3.4
and 4.0. You only need [Rust](https://rustup.rs) when no precompiled gem
matches your platform and the gem builds from source.

## Install the storage

The generator adds one migration. The models and the channel ship in the gem,
as `ActionText::RichText` ships in Action Text.

```bash
bin/rails generate yrby:install
bin/rails db:migrate
```

## The server side

There is no channel to write. Render the document in a view that already
requires edit permission for the record:

```erb
<%= collaborative_document_tag @post, :body %>
```

The tag renders a signed grant for that record and attribute. When the browser
subscribes, the gem's `Y::DocumentChannel` checks the grant and finds the
record. It saves each change before it acknowledges it, to `Y::Document`, or to
`Y::EncryptedDocument` for attributes declared `encrypted: true`.

The client sends only the grant. The channel rejects a grant that is missing,
tampered with, expired, or signed for a different attribute. It also rejects
one whose record has been deleted. Your controller already authorized the user
when it rendered the page. The channel trusts the grant because only your
server can sign one. To also check the user's current permissions at subscribe
time, see [The document channel](/docs/document-channel).

The document is stored as rows in your database, and you can read it back in
Ruby:

```ruby
doc = @post.collaborative_document(:body).y_doc
doc.read_text("content")  # for rich text, use Y::Lexxy.new(doc).to_html
```

Some apps need documents keyed by room, a different store, or their own
authorization. For those, generate an application channel with
`bin/rails generate yrby:install --channel`. It includes the same concern that
`Y::DocumentChannel` uses, and it's a few lines long.
[The document channel](/docs/document-channel) covers it.

## The browser side

The tag renders a `<yrby-document>` element that connects by itself once you
import it. When the document has synced, your listener receives it and passes
it to your editor binding:

```js
import "yrby-client/element"

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bindYourEditor(target, detail.doc, detail.provider)
  detail.signal.addEventListener("abort", () => editor.destroy(), { once: true })
})
```

`yrby:synced` fires once per lease, after the first catch-up with the server.
Bind the editor in that listener. Most editor bindings seed an empty document
when they mount. If two clients bind before the server's state arrives, each
inserts its own top-level node and the document ends up with both.

When the signal aborts, detach the editor. Your binding owns the editor and its
listeners. yrby owns the document, the provider, and the shared consumer, so
don't destroy those in your cleanup. The event bubbles, so one listener on
`document` also handles elements added to the page later.

If the user leaves the page with unsent edits, the session keeps them and
finishes delivering them. The next visit loads the saved content from Rails,
in a new `Y.Doc` with a fresh undo history. The
[client lifecycle](/docs/javascript-client#document-sessions-and-navigation)
has the details. Open the [record-backed editor](/examples/document) in two
windows to try it.

On AnyCable, give the elements an Action Cable compatible consumer before any
of them connect:

```js
import { YrbyDocumentElement } from "yrby-client/element"
import { createConsumer } from "@anycable/web"

YrbyDocumentElement.consumer = createConsumer()
```

See [The JavaScript client](/docs/javascript-client) for the rest of the API.

## What yrby covers

`yrby` binds the parts of `y-crdt` you need to sync and persist collaborative
documents: a `Doc`, awareness, and the y-websocket protocol primitives. The
server doesn't need to know what's in a document to sync it. It applies
updates, answers sync handshakes, and saves changes without reading them. The
editor in the browser defines the document's structure. When you want to read
the contents in Ruby, use `Doc#read_text` or `Doc#read_map`.

The API is small. Most of the work went into durability, delivery guarantees,
correctness, and thread safety.

## Editors

yrby syncs opaque Yjs updates, so any editor with a Yjs binding works. The demo
app in the repo runs four of them, and CI drives each one in a real Chrome.

| Editor | Yjs binding |
|---|---|
| [Tiptap](https://tiptap.dev) (v2) | `@tiptap/extension-collaboration` |
| [Lexxy](https://github.com/basecamp/lexxy) (Lexical) | [`lexxy-realtime`](https://www.npmjs.com/package/lexxy-realtime) |
| [Rhino Editor](https://github.com/KonnorRogers/rhino-editor) (Tiptap 3) | `@tiptap/extension-collaboration` + `-caret` |
| [CodeMirror 6](https://codemirror.net) | `y-codemirror.next` |

The same channel also syncs Yjs shapes with no editor: a whiteboard on a
`Y.Map`, a kanban board on a `Y.Array`, a spreadsheet on a `Y.Array` of nested
`Y.Map`s. This site runs six [live demos](/demos). One is a Lexxy editor built
on [lexxy-realtime](https://github.com/jpcamara/lexxy-realtime). After every
change, the server renders that document to HTML with `Y::Lexxy` and saves it
to a plain column.

## Reading a document in Ruby

You can rebuild a document on the server for search, exports, or emails,
without Node:

```ruby
doc.read_text("prosemirror")  # => plain text of a Y.Text root, or nil
doc.read_xml("root")          # => text of an XML root, one block per line
doc.read_map("state")         # => a Y.Map root as a JSON string
doc.read_array("cards")       # => a Y.Array root as a JSON string
```

To get HTML that matches the editor's own serializer, see
[Server-side rendering](/docs/rendering).

## Thread safety

You can share a `Doc` across Ruby threads. Puma threads, Action Cable
connection threads, and background jobs can all use the same one at once, and
your code doesn't need to lock it.

Every method that does real CRDT work releases Ruby's Global VM Lock while the
native code runs. On MRI, that means CRDT work runs in parallel across
threads, and a thread applying a large update doesn't block the others.
