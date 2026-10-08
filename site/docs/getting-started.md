# Getting started

yrby lets several people edit the same field in your Rails app at once, such
as a post's body. It wraps [y-crdt](https://github.com/y-crdt/y-crdt), the Rust
version of Yjs, for Ruby. On top of that it adds a sync channel for Action Cable
and AnyCable, a browser client, and tools to read and render the saved content
in Ruby. You don't need to run Node.

In yrby, a document is the Yjs state for one record attribute, such as
`@post.body`. Browsers sync it over Action Cable, and the server stores it as
`Y::Document` and `Y::DocumentUpdate` rows.

## Install

Add both gems, then install the browser package and its peer dependencies:

```ruby
# Core CRDT and protocol primitives
gem "yrby"

# The Rails side: the sync channel, the storage models, the generator
gem "yrby-rails"
```

```
npm install yrby-client yjs y-protocols @rails/actioncable
```

yrby needs Ruby 3.4 or newer. Releases include precompiled gems for Ruby 3.4
and 4.0. You only need [Rust](https://rustup.rs) when no precompiled gem
matches your platform and the gem builds from source.

## Install the storage

The generator adds one migration. The models and the channel come with the gem,
so there's nothing else to generate.

```bash
bin/rails generate yrby:install
bin/rails db:migrate
```

## The server side

You don't need to write a channel. Render the tag in a view that only users who
can edit the record can see:

```erb
<%= collaborative_document_tag @post, :body %>
```

The tag includes a signed token for that record and attribute. The browser
subscribes to the gem's `Y::DocumentChannel` with it, and the channel looks up
the record. The channel saves each change before it confirms it. It uses
`Y::Document`, or `Y::EncryptedDocument` when the attribute is declared with
`encrypted: true`.

The browser only ever sends that token. The channel rejects it if it's missing,
tampered with, expired, signed for a different attribute, or points at a
deleted record. Only your server can sign a token, so a valid one means your
controller already let this user see the page. To also check the user's
current permissions when they subscribe, see
[The document channel](/docs/document-channel).

The saved state lives in `Y::Document` rows in your database, and you can read
the post's body back in Ruby:

```ruby
doc = @post.collaborative_document(:body).y_doc
doc.read_text("content")  # for rich text, use Y::Lexxy.new(doc).to_html
```

If you need a Yjs document keyed by room instead of a record, a different
store, or your own authorization, generate your own channel with
`bin/rails generate yrby:install --channel`. It's a few lines long and uses the
same concern as `Y::DocumentChannel`.
[The document channel](/docs/document-channel) covers it.

## The browser side

The tag renders a `<yrby-document>` element. Import it once and it connects by
itself. When the Yjs document (`Y.Doc`) has synced, your listener gets it and
hands it to your editor:

```js
import "yrby-client/element"

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bindYourEditor(target, detail.doc, detail.provider)
  detail.signal.addEventListener("abort", () => editor.destroy(), { once: true })
})
```

`yrby:synced` fires once the Yjs document has caught up with the server. Wait for
it before you attach the editor. Most editor bindings add an empty paragraph when
they start. If two people attach before the server's copy arrives, the post's body
ends up with both paragraphs.

When the signal aborts, remove the editor and its listeners. Leave the Yjs
document, the provider, and the cable consumer alone, because yrby manages
those. The event bubbles, so one listener on the page's `document` also covers
elements added to the page later.

If the user leaves the page before their edits are sent, yrby keeps sending
them as long as the tab stays open. The next visit loads the saved content from
Rails, with a fresh undo history. The
[JavaScript client](/docs/javascript-client#document-sessions-and-navigation)
page has the details, and the [record-backed editor](/examples/document) lets
you try it in two windows.

On AnyCable, set the consumer before any element connects:

```js
import { YrbyDocumentElement } from "yrby-client/element"
import { createConsumer } from "@anycable/web"

YrbyDocumentElement.consumer = createConsumer()
```

See [The JavaScript client](/docs/javascript-client) for the rest of the API.

## What yrby covers

`yrby` binds the parts of `y-crdt` you need to sync and save Yjs documents: a
`Doc`, awareness, and the y-websocket protocol primitives. The server doesn't
need to know what's in a Yjs document to sync it. It applies updates, answers
sync handshakes, and saves changes without reading them. The editor in the
browser defines its structure. When you want to read
the contents in Ruby, use `Doc#read_text` or `Doc#read_map`.

The API is small. Most of the gem's code deals with saving changes, delivering
them reliably, and thread safety.

## Editors

yrby doesn't look inside Yjs updates, so any editor with a Yjs binding works.
The demo app in the repo runs four of them, and CI types into each one in real
Chrome.

| Editor | Yjs binding |
|---|---|
| [Tiptap](https://tiptap.dev) (v2) | `@tiptap/extension-collaboration` |
| [Lexxy](https://github.com/basecamp/lexxy) (Lexical) | [`lexxy-realtime`](https://www.npmjs.com/package/lexxy-realtime) |
| [Rhino Editor](https://github.com/KonnorRogers/rhino-editor) (Tiptap 3) | `@tiptap/extension-collaboration` + `-caret` |
| [CodeMirror 6](https://codemirror.net) | `y-codemirror.next` |

The same channel also syncs Yjs documents that aren't text, such as a whiteboard
on a `Y.Map`, a kanban board on a `Y.Array`, or a spreadsheet on a `Y.Array` of
nested `Y.Map`s. This site has six [live demos](/demos). In the Lexxy one,
built on [lexxy-realtime](https://github.com/jpcamara/lexxy-realtime), the
server renders the rich text to HTML with `Y::Lexxy` after every change and
saves it to a plain column.

## Reading a Yjs document in Ruby

You can read a Yjs document on the server for search, exports, or emails:

```ruby
doc.read_text("prosemirror")  # => plain text of a Y.Text root, or nil
doc.read_xml("root")          # => text of an XML root, one block per line
doc.read_map("state")         # => a Y.Map root as a JSON string
doc.read_array("cards")       # => a Y.Array root as a JSON string
```

For HTML that matches what the editor produces, see
[Server-side rendering](/docs/rendering).

## Thread safety

You can share a `Doc` across Ruby threads. Puma threads, Action Cable
connection threads, and background jobs can all use the same one at once, and
your code doesn't need to lock it.

Methods that do real CRDT work release Ruby's Global VM Lock while the native
code runs. So on MRI, several threads can do CRDT work in parallel, and a big
update on one thread doesn't hold up the others.
