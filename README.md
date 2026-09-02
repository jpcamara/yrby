# yrby

[![CI](https://github.com/jpcamara/yrby/actions/workflows/ci.yml/badge.svg)](https://github.com/jpcamara/yrby/actions/workflows/ci.yml)

yrby (pronounced "yer-bee") makes Rails a real Yjs backend. It binds
[y-crdt](https://github.com/y-crdt/y-crdt), the Rust engine behind Y.js, into
Ruby, and builds the rest of the stack around it: a sync server for Action
Cable and AnyCable, a browser provider, and server-side reading and rendering
of the documents. Real-time collaboration in a Rails app with no Node process
anywhere in the path.

![Two people typing on separate lines of the same document, each keystroke synced through a Rails server, seen from a third browser with labeled carets](docs/images/collab.gif)

On the server, `yrby-rails` implements the full y-websocket protocol
(document sync plus presence) as a channel concern. Its delivery contract is
stricter than the usual Yjs servers: every update is ack-tracked and durably
recorded before it is acknowledged or broadcast to anyone. Replaying your
store always rebuilds the document, across any number of processes.
([Delivery guarantees](#delivery-guarantees))

In the browser, `yrby-client`'s `ActionCableProvider` connects anything that
speaks Yjs. The demo app runs four rich text editors, and CI drives each one
in real Chrome: Tiptap, [Lexxy](https://www.npmjs.com/package/lexxy-realtime),
Rhino Editor, and CodeMirror. The same channel also syncs Yjs shapes with no
editor at all: a whiteboard on a `Y.Map`, a kanban board on a `Y.Array`, a
co-filled form. ([Editors](#editors))

In Ruby, the documents are readable without a browser. `Doc#read_text` and
`Doc#read_map` reconstruct contents for search, validation, and exports.
`Y::Tiptap` and `Y::Lexxy` render a document to HTML byte-identical to the
editor's own serializer, take rules for your app's custom nodes, and drop
straight into ActionText. ([Rendering to HTML](#rendering-to-html))

Underneath, the core is built for a production Rails deployment. A `Doc` is
thread-safe across Puma and ActionCable threads. Native CRDT work runs with
the GVL released, so it parallelizes on MRI. Incoming frames are validated
before anything processes them, and multi-process and AnyCable setups are
tested end to end. ([Thread Safety](#thread-safety))

The whole integration is one view helper, rendered where the page is
already authorized to edit the record:

```erb
<%= collaborative_document_tag @post, :body %>
```

The tag renders a signed grant for exactly that record and attribute — the
way `turbo_stream_from` signs its stream names. The gem's own
`Y::DocumentChannel` verifies the grant on subscribe and records every
change as `Y::Document` rows before acknowledging it. Clients never name
documents, and there is no channel to write.

The tag is an auto-connecting element — importing it once is the whole wiring,
and your code receives the synced document to hand to any editor that speaks
Yjs:

```js
import "yrby-client/element"

document.querySelector("yrby-document").addEventListener("yrby:synced", ({ target }) => {
  bindYourEditor(target.doc) // any Yjs editor binding
})
```

And the document is rows in your database, readable without a browser:

```ruby
doc = Y::Doc.new
doc.apply_update(Y::Document.for(post, :body).load_state)
doc.read_text("content")  # or Y::Lexxy.new(doc).to_html for rich text
```

Install the gem and the npm package:

```
gem install yrby-rails # depends on yrby
npm install yrby-client

bin/rails yrby:install && bin/rails db:migrate
```

## Contents

- [Scope](#scope)
- [Durability and delivery](#durability-and-delivery)
- [What about yrb?](#what-about-yrb)
- [Testing](#testing)
- [Install](#install)
- [Docs](#docs)
- [Editors](#editors)
- [Usage](#usage)
  - [Doc (Low-Level Document Sync)](#doc-low-level-document-sync)
  - [Reading document contents](#reading-document-contents)
  - [Pending structs and gap-free state](#pending-structs-and-gap-free-state)
  - [Rendering to HTML](#rendering-to-html)
  - [Protocol codec (module functions)](#protocol-codec-module-functions)
  - [ActionCable Integration](#actioncable-integration)
- [Thread Safety](#thread-safety)
  - [Parallelism (GVL release)](#parallelism-gvl-release)
- [Message Type Constants](#message-type-constants)
- [Sync Flow](#sync-flow)
- [Development](#development)
- [License](#license)
- [Acknowledgments](#acknowledgments)

## Scope

`yrby` binds just the part of `y-crdt` you need to *sync and persist* collaborative
documents - a `Doc`, awareness, and the y-websocket protocol primitives. By default
the Ruby side treats a document as opaque CRDT state: it applies updates, answers
sync handshakes, and records deltas without reaching into the contents - the browser
editor owns the document's shape. When you do need to look inside, `Doc#read_text`
and `Doc#read_map` reconstruct it server-side, in Ruby.

## Durability and delivery

The surface is intentionally small, but the focus is durability, resiliency, delivery
guarantees, correctness, and thread safety.

Towards that goal, `yrby` adds opinionated defaults on top of normal Yjs syncing:

- Built-in update acknowledgement: the `ActionCableProvider` in `yrby-client` keeps
  sending an update until the server acks it, and [`yrby-rails`](https://rubygems.org/gems/yrby-rails)
  only acks once the update is durably recorded. That gives you at-least-once
  delivery, and because CRDT updates are idempotent a duplicate is a no-op.
- Gap awareness: an update can arrive before another update it depends on (a
  "causal gap"). `yrby` records and acks it like any other, and the document
  heals on its own once the missing update arrives; its sender keeps
  retransmitting it until it is acked. `Doc#pending?` and the `on_gap` hook
  tell you when a document is waiting on a missing update.
  ([Causal gaps](#causal-gaps))

## What about [yrb](https://github.com/y-crdt/yrb)?

`yrb` has a much larger interface that gives you most of the Yjs type system - 
shared text, arrays, maps, XML - to build and query documents in Ruby. It was a great
inspiration for my use of Yjs in Ruby/Rails, and I originally considered building
on top of it. There are a few reasons I went with `yrby` instead:

- `yrb` is largely unmaintained. It was built as an experiment for GitLab, and the original
  author mostly moved onto other projects.
- [It isn't thread-safe](https://github.com/y-crdt/yrb/issues/72). It segfaults in a threaded
  environment (such as ActionCable...)
- It's a much larger set of features to maintain, which most people don't need. The vast
  majority of people manipulate Y.js documents in the browser, not from a server-side language.

## Testing

Ruby and Rust unit tests cover the core. CI also runs the npm client tests and a
Rails demo smoke slice against the real ActionCable stack. The demo includes
heavier local suites for hostile input, crash recovery, multi-browser editing,
AnyCable, and load testing. The benchmark note below is from a single laptop.
Issues and PRs are welcome.

## Install

```ruby
# Core CRDT + protocol primitives:
gem "yrby"

# For the Rails side (the sync channel, document models, the generator).
# Formerly yrby-actioncable; that name stops at 0.3.1.
gem "yrby-rails"
```

Requires Ruby 3.4 or newer. The release workflow builds precompiled gems for
Ruby 3.4 and 4.0 across the supported Ruby platforms, with native smoke tests
on Linux x86_64 and macOS arm64. Installing from a matching platform gem needs
no Rust; a source build needs [Rust](https://rustup.rs).

To work on the gem itself:

```bash
git clone https://github.com/jpcamara/yrby
cd yrby
bundle install
bundle exec rake compile test
```

The rest of the dev setup, plus the demo, is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Docs

- The ActionCable concern and a quickstart are [below](#actioncable-integration).
- [`examples/actioncable-demo`](examples/actioncable-demo): a runnable Rails +
  Tiptap app with collaborative cursors, the AnyCable setup, a Postgres store,
  and the test/load suites.
- [CHANGELOG.md](CHANGELOG.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Editors

yrby syncs opaque Yjs updates, so it works with any editor that has a Yjs
binding. The demo app runs four, and CI drives each one in real Chrome:
concurrent typing with every keystroke accounted for, remote cursors,
local-only undo, and byte parity between the server-side renderers and the
editor's own serializer. Each page is a working integration to copy from:

| Editor | Yjs binding | Demo code |
|---|---|---|
| [Tiptap](https://tiptap.dev) (v2) | `@tiptap/extension-collaboration` | [`app.js`](examples/actioncable-demo/frontend/src/app.js) |
| [Lexxy](https://github.com/basecamp/lexxy) (Lexical) | [`lexxy-realtime`](https://www.npmjs.com/package/lexxy-realtime) | [`lexxy.js`](examples/actioncable-demo/frontend/src/lexxy.js) |
| [Rhino Editor](https://github.com/KonnorRogers/rhino-editor) (Tiptap 3) | `@tiptap/extension-collaboration` + `-caret` | [`rhino.js`](examples/actioncable-demo/frontend/src/rhino.js) |
| [CodeMirror 6](https://codemirror.net) | `y-codemirror.next` | [`codemirror.js`](examples/actioncable-demo/frontend/src/codemirror.js) |

The demo also syncs plain Yjs shapes with no editor at all (a whiteboard
on a `Y.Map`, a kanban board on a `Y.Array`, a co-filled form) over the
same channel. The demo README's "Using this in your own app" section has
the integration recipe, and its `NoteMaterializer` shows how to render a
document to ActionText server-side with `Y::Tiptap` or `Y::Lexxy`.

## Usage

### Doc (Low-Level Document Sync)

```ruby
require "y"

# Create docs
doc = Y::Doc.new        # random client ID
doc = Y::Doc.new(12345) # specific client ID (used for CRDT identity)

# Encoding
doc.encode_state_vector           # => current state vector
doc.encode_state_as_update        # => full update (lossless: keeps pending)
doc.encode_state_as_update(sv)    # => update diff against state vector
doc.compacted_state_update        # => full update, gap-free (excludes pending)

# Applying updates
doc.apply_update(update_bytes)    # apply raw V1 update
doc.pending?                      # => true if holding un-integrable pending structs
doc.update_ready?(update)         # => true if update would integrate cleanly (no gap)
doc.update_advances?(update)      # => true if update moves integrated state forward

# Sync protocol
doc.sync_step1                    # => SyncStep1 message (this doc's state vector)
doc.handle_sync_message(data)     # => [msg_type, sync_type, response]; answers a
                                  #    peer's SyncStep1 with full state (lossless,
                                  #    pending included, like Y.js)
```

### Reading document contents

Reconstruct a document server-side (search, exports, emails, SSR) with no
Node process:

```ruby
doc.read_text("prosemirror")  # => plain text of a Y.Text root, or nil
doc.read_xml("root")          # => text of an XML root, one block per line
doc.read_map("state")         # => a Y.Map root as a JSON string; JSON.parse it
doc.read_array("cards")       # => a Y.Array root as a JSON string; JSON.parse it
```

### Pending structs and gap-free state

If a doc applies an update whose causally-prior update is missing (a "gappy"
update), yrs parks it as a **pending** struct: the integrated state vector stays
empty, but the pending block is held as a recovery buffer and heals if the
missing dependency later arrives. `Doc#pending?` reports this.

Pending structs travel like any other state. `handle_sync_message` answers
`SyncStep1` with the doc's full state, pending included, just like Y.js's
`encodeStateAsUpdate`: a peer parks the pending struct the same way this doc
did and heals it the same way. The one place pending must not go is a
compacted snapshot:

- `Doc#compacted_state_update` returns a gap-free full-state update for
  compaction. Folding a log into one blob would otherwise freeze an
  un-integrable struct into the base state forever. It's non-destructive: the
  doc keeps its pending.
- `encode_state_as_update` stays lossless, so persistence and serving keep
  the raw pending bytes and the gap can still heal.

### Rendering to HTML

Schema-pinned renderers turn a collaborative document into HTML on the
server, with no Node process or headless editor. Each is an editor-specific
class (byte-for-byte with that editor's own serializer) built on a core base
any other editor extends with rules: `Y::Tiptap` on `Y::ProseMirror` for
ProseMirror documents, and `Y::Lexxy` (the
[Lexxy](https://github.com/basecamp/lexxy) editor) on `Y::Lexical`. Each
returns `nil` for a root that belongs to the other schema.

#### `Y::Tiptap` (and `Y::ProseMirror`, its base)

```ruby
tiptap = Y::Tiptap.new(doc)
tiptap.to_html            # the "default" fragment (Tiptap's default root)
tiptap.to_html("content") # or another XML root
```

The output matches Tiptap's own `getHTML()`, checked byte-for-byte in the tests
against a document captured from a real editor. It follows
[`tiptap-php`](https://github.com/ueberdosis/tiptap-php) and reads both name
styles editors use: Tiptap's `bulletList`/`bold` and prosemirror-schema-basic's
`bullet_list`/`strong`.

It covers paragraphs, headings, blockquotes, bullet/ordered/task lists, code
blocks, links, images, mentions, details, hard breaks, horizontal rules,
tables, text styles (color, font family), and every text mark. A table renders
as semantic `<table><tbody>`, without the column-width styling Tiptap's editor
view adds.

The support is layered like the Lexical side: `Y::ProseMirror` covers core
ProseMirror natively (prosemirror-schema-basic plus the prosemirror-tables
family) and Tiptap's extension nodes (task lists, mentions, the details
family) are `Y::Tiptap`'s rule set (`Y::Tiptap::NODES`), built on the
extension API below. Marks stay in the base: mark rendering (nesting order,
`textStyle` CSS, `code` exclusivity) runs through native text-run machinery
that node rules don't reach, so `Y::ProseMirror` renders Tiptap's mark set
as-is and `rules.mark` overrides individual marks.

#### `Y::Lexxy` (and `Y::Lexical`, its base)

```ruby
lexxy = Y::Lexxy.new(doc)
lexxy.to_html            # the "root" fragment (Lexical's default root name)
lexxy.to_html("notepad") # or another XML root
```

The HTML is identical to what a `lexxy-editor` submits to Rails (its `value`).
The tests check this byte-for-byte against a document captured from a real
editor. Stock Lexical has no canonical serializer (every editor configures
its own), so the editor-specific class carries the editor's name, and
`Y::Lexical` is the core-Lexical base: paragraphs, headings, quotes, code,
lists, tables, links, and the full text-format model, for any other Lexical
editor to extend with rules.

It handles the whole Lexxy 0.9.x node set: paragraphs, headings, every text
format and their combinations, links, the four list types and nesting,
blockquotes, code blocks, tabs and soft breaks, horizontal rules, tables with
header cells, image galleries, and ActionText attachments (uploads and
mentions both emit `<action-text-attachment>` elements that ActionText can
re-render).

Internally that support is layered: `Y::Lexical` covers core Lexical
structure natively, and everything Lexxy adds, its node types (attachments,
galleries) and its decorations of core nodes (the table wrapper, header-cell
styling, nested-list classes), is `Y::Lexxy`'s rule set
(`Y::Lexxy::NODES`), built on the extension API below. The gem's own Lexxy
support is the API's first consumer: an app rule for one of those types
simply replaces it.

In both renderers an unknown node keeps its content: text and nested blocks
fall back to readable markup rather than disappearing.

#### Custom nodes and marks

The built-in schemas are pinned to what Tiptap and Lexxy ship, but apps add
their own node types. Both renderers take rules for them. A rule is checked
before the built-in schema, so it can add a node type or replace how a
built-in renders.

Rules register in a block, one `rules.node` call per type. A declarative
rule is markup as data, rendered natively:

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "callout", tag: "aside",
                        attrs: { "class" => ["callout callout--", :kind] },
                        contains: :blocks
end
```

`tag` names the element. `attrs` values are templates: a string is a literal,
a symbol reads that attribute off the node, an array concatenates both kinds;
an attribute that resolves empty is left out. `text` (same template form)
emits literal text content. `contains` declares what lives inside the node: `:inline` (formatted text,
the default), `:blocks` (child block nodes, a container), or `:none` (a
leaf). `void: true` skips the closing tag.

You don't have to guess any of those names or shapes. Editors store types
and attributes under names you'd never predict (Rhino's strike mark is
`rhino-strike`; Lexical prefixes its own props `__`), so ask a real
document instead: make one in your editor using your custom node, then:

```ruby
Y::Tiptap.new(doc).node_types
# => { "callout"   => { "count" => 2, "attrs" => ["kind"],
#                       "children" => ["paragraph"], "text" => false,
#                       "handled" => nil },
#      "paragraph" => { ..., "handled" => "builtin" } }
```

`handled` nil marks the types that still need a rule; `attrs` are the stored
names your templates and blocks will read; `children` plus `text` is how you
pick `contains:` (child block types → `:blocks`; text → `:inline`).

When markup-as-data isn't enough, give the node a block:

```ruby
lexical = Y::Lexical.new(doc) do |rules|
  rules.node "video_embed" do |node|
    src = ERB::Util.html_escape(node.attrs["__src"])
    %(<video controls src="#{src}"></video>)
  end
end
```

The block gets the node's type, its stored attributes, `node.content` (the
children, already rendered to HTML), and `node.child_types`, the node's
element/block children by type, in document order. `child_types` answers the
structural questions attributes can't: how many images a gallery holds, or
whether a list item carries a nested list. Whatever the block returns is
spliced into the output as-is: it's trusted HTML, so escape any values you
interpolate. To set the content mode for a callback, give the node both:
`rules.node "embed", contains: :blocks do |node| ... end`.

Callbacks never run while the document is locked. The render finishes first
(inside one read transaction, GVL released), then the blocks run and their
output is spliced in, so a callback can safely read or even write the same
doc. With no callback rules, `to_html` skips the splicing entirely.

Blocks are the escape hatch for everything the declarative form can't say,
and they're proven sufficient: `Y::Lexxy` and `Y::Tiptap` are themselves
built on this API (`lib/y/lexxy.rb`, `lib/y/tiptap.rb`): simple nodes as
declarative hashes, everything with logic as plain methods mapped by node
type (a `Method` responds to `call` like any lambda), and the fixture tests
hold their output byte-identical to a live editor's.

The ProseMirror side also takes custom marks:

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.mark "comment", tag: "span", attrs: { "data-comment-id" => :id }
end
```

Symbol refs resolve against the mark's own attributes. A custom mark wraps
outside every built-in mark; several on one run nest alphabetically. A rule
for a built-in mark name (`"bold"`) replaces its built-in tag.

##### Worked examples

A video-embed node from an app's Tiptap extension, a type the pinned schema
has never heard of:

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "videoEmbed" do |node|
    src   = ERB::Util.html_escape(node.attrs["src"])
    title = ERB::Util.html_escape(node.attrs["title"] || "Video")
    %(<figure class="video"><iframe src="#{src}" title="#{title}" allowfullscreen></iframe></figure>)
  end
end
```

Resolving mentions against the database. Blocks run after the document read
has finished, so hitting ActiveRecord (or the doc itself) inside one is safe:

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "mention" do |node|
    user = User.find_by(id: node.attrs["id"])
    next "<span>@unknown</span>" unless user

    %(<a class="mention" href="/users/#{user.id}">@#{ERB::Util.html_escape(user.handle)}</a>)
  end
end
```

Overriding a shipped rule: rendering Lexxy uploads as real image markup
instead of the `<action-text-attachment>` elements ActionText re-renders:

```ruby
lexxy = Y::Lexxy.new(doc) do |rules|
  rules.node "action_text_attachment" do |node|
    src     = ERB::Util.html_escape(node.attrs["src"])
    alt     = ERB::Util.html_escape(node.attrs["altText"].to_s)
    caption = node.attrs["caption"].to_s
    html = %(<img src="#{src}" alt="#{alt}" loading="lazy">)
    html += "<figcaption>#{ERB::Util.html_escape(caption)}</figcaption>" unless caption.empty?
    "<figure>#{html}</figure>"
  end
end
```

Markup that depends on structure: `node.child_types` lists the node's
element/block children in document order, so a layout container can size
itself by its column count while the columns themselves stay declarative:

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "columns", contains: :blocks do |node|
    %(<div class="columns columns--#{node.child_types.length}">#{node.content}</div>)
  end
  rules.node "column", tag: "div", attrs: { "class" => "column" }, contains: :blocks
end
```

Content-aware overrides: dropping the empty paragraphs an editor keeps
around the cursor, since `node.content` arrives already rendered:

```ruby
lexical = Y::Lexical.new(doc) do |rules|
  rules.node "paragraph" do |node|
    node.content.empty? ? "" : "<p>#{node.content}</p>"
  end
end
```

For a larger reference, the gem's own editor schemas ship this way; see
`Y::Lexxy::NODES` in `lib/y/lexxy.rb` (declarative hashes for the simple
nodes, a plain method per node that needs logic (galleries, list items,
header cells, both attachment types) mapped with `method(:name)`) and
`Y::Tiptap::NODES` in `lib/y/tiptap.rb` (task lists, mentions, the details
family).

### Protocol codec (module functions)

Classifying and unwrapping wire frames is stateless, so it's exposed as
`Y` module functions rather than a class. The server never holds presence
or document state to route a frame; presence lives in the browser clients, and
the server only relays awareness frames opaquely.

```ruby
Y.message_kind(frame)         # => 0 drop / 1 step1 / 2 update / 3 awareness / 4 query
Y.update_from_message(frame)  # => the document delta carried by a frame, or nil
Y.wrap_update(update_bytes)   # => wrap a raw doc update as a sync Update frame
```

### ActionCable Integration

In a Rails app, one generator creates the storage migration — the models
and `Y::DocumentChannel` ship in the gem:

```bash
bin/rails yrby:install
bin/rails db:migrate
```

The models ship in the gem, the way Action Text owns
`ActionText::RichText`:

- **`Y::Document`**: one row per document, addressed two ways: by `key`
  (what a channel addresses; one opaque, unique string, sometimes
  app-supplied, never parsed) and, optionally, by polymorphic `record` +
  `name` (which model attribute it backs; `name` is the attribute name,
  `"body"`; one document per attribute per record, the
  ActionText::RichText scheme). Key-only documents leave the binding nil.
  Either side can arrive first: `Y::Document.for(record, name)` finds or
  creates the binding, derives a readable key (`post/1/body`), and adopts
  a key-only row already holding that key, so a channel writing first and
  a binding created later converge on one document. The row also holds
  the merged `state` snapshot, CRDT state only; derived data (rendered
  HTML, search text) is the application's job, typically in the channel's
  on_change. `.load_state(key)` / `.append(key, update)` are the store
  calls the channel concern defaults to.
- **`Y::DocumentUpdate`**: the uncompacted tail, one delta per row,
  compacted into `state` and deleted once the tail reaches `compact_every`
  (default 64). Loading reads the snapshot plus the current tail; an
  empty tail returns `state` directly. Compaction serializes on a
  per-document row lock and skips causally-gapped rows; they're
  quarantined until they heal rather than compacted into state or
  deleted. Destroying a document deletes its updates with it.

Encrypted storage: `Y::EncryptedDocument` stores `state` and update
payloads through Active Record encryption on the same tables, the way
`ActionText::EncryptedRichText` does. Declare it on the model — encryption
is a property of the attribute's storage, never something a page or client
chooses:

```ruby
class Post < ApplicationRecord
  has_collaborative_document :body, encrypted: true
end
```

`Y::DocumentChannel` consults the declaration and routes every load and
append for that attribute through the encrypted class; undeclared
attributes keep plain `Y::Document`. In a channel of your own, point
`on_load`/`on_change` at `Y::EncryptedDocument` instead. Either way,
configure your app's encryption keys and use one access path per document:
rows written encrypted read back as ciphertext through the plain classes.

The migration creates `y_documents` and `y_document_updates`. To rename
them, edit the generated migration and point `Y::Document.table_name` /
`Y::DocumentUpdate.table_name` at the new names in an initializer.

Storage is swappable: the channel only needs `on_load` and `on_change`
answered, and they can point at anything.

`include Y::ActionCable` (from the `yrby-rails` gem) is the channel
integration: the y-websocket protocol (document sync +
awareness/presence) over ActionCable.

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load { |key| Y::Document.load_state(key) }          # rebuild from storage
  on_change { |key, update| Y::Document.append(key, update) } # record, then broadcast

  def subscribed
    sync_subscribed params[:id]
  end

  def receive(data)
    sync_receive(data, params[:id])
  end

  private

  # Everyone is denied until you wire this to your app's auth —
  # sync_subscribed rejects the subscription unless it returns true.
  def authorized?(_document_key) = false
end
```

For documents that hang off a record, `Y::Collaborative` (included into
Active Record by the engine) provides the token flow `authorized?` wants:
the page mints a signed GlobalID scoped to one attribute, and the channel
trades it back for the record — so clients never name documents at all.

```erb
<%# the view names the document, signed %>
<%= tag.div data: { sgid: post.collaborative_sgid(:body) } %>
```

```ruby
# the channel trades the token back for the record
def authorized?(_key) = record.present? && record.editable_by?(current_user)
def record = @record ||= Y::Collaborative.locate(params[:sgid], :body)
```

A token minted for `:body` verifies only under `:body`'s purpose
(`"yrby/body"`); tampered, expired, or wrong-attribute tokens locate nothing.

The concern is store-backed. A handshake is answered from `on_load`; document
changes are recorded through `on_change`, then broadcast. Nothing
authoritative is kept in ActionCable process memory, so
AnyCable RPC workers, Puma workers, and separate dynos can all handle messages
for the same document as long as they share the same store and cable adapter.

`on_load` and `on_change` are required. If either is missing, the channel fails 
before it can acknowledge or broadcast edits. Presence is ephemeral:
awareness frames are relayed, and `yrby-client` sends a best-effort
presence-removal frame on disconnect/pagehide, with the client-side awareness
timeout as the fallback for abrupt disconnects.

Incoming frames are validated as a single well-formed protocol message before
anything processes or relays them. Malformed, truncated, multi-message,
oversized, or unknown frames are dropped. A bad frame can't crash the process: a
Rust panic is caught at the FFI boundary and re-raised as a Ruby exception. And
no single client can relay garbage that breaks the others in a room.

#### Delivery guarantees

The contract is the same at every scale: one process, or hundreds across many
servers:

- **The document always converges.** CRDT updates are commutative and
  idempotent, so out-of-order, duplicate, or concurrent delivery all converge to
  the same correct document. This needs no coordination and holds everywhere.
- **An acked update is durable, even one that arrived out of order.** An
  update with a missing dependency is recorded and acked like any other, and
  parks as pending in the document. That missing dependency is an update some
  client still holds unacked, so that client keeps retransmitting it until
  the server records it, and the gap closes. The ack loop is the guarantee.
  See [Causal gaps](#causal-gaps).
- **`on_change` is at-least-once, and the durable guarantee is that replaying the
  log reconstructs the document.** Every update triggers `on_change` before it's acked or
  broadcast (record-before-distribute). If exactly-once updates matter for you, **you
  must make `on_change` idempotent**. But remember that the CRDT can handle duplicates.
- **A raising `on_change` rejects the update implicitly.** If the block raises,
  the update is neither acked nor broadcast (record-before-distribute stops both).
  There is no negative-ack: the client simply never receives the ack, keeps the
  update pending, and retransmits on its timer/reconnect. This is built for
  *transient* failures (the store is briefly down → a retry lands). A block that
  raises *deterministically* (a validation that always fails for this edit)
  will be retried forever, since nothing tells the client to stop. Enforce hard
  rejections before the edit reaches `on_change` (channel authorization in
  `subscribed`), not by raising inside it.
- **An over-cap frame is dropped the same silent way.** A frame larger than
  `max_frame_bytes` (default 8 MiB) is dropped before decoding (no ack, no
  broadcast) to bound the work a client can force. For a genuine document
  update that means the same implicit rejection as above: unacked, retransmitted
  forever. Normal typing never approaches the cap, but a large paste, an embedded
  image, or a big initial `SyncStep2` can. The drop is logged (`warn` for
  over-cap, `debug` for undecodable) with the document key and update id so it's
  findable; override `sync_log_context` on the channel to add a user/connection
  id. Size the cap for your largest expected payload, and reject
  genuinely-too-big content upstream rather than relying on the cap to reject it
  gracefully.

#### Causal gaps

Yjs updates can arrive out of order: an update can reach the server before
another update it depends on. yrby treats that as normal. The update is
recorded and acked like any other, parks as a pending struct in the document,
and integrates on its own the moment the missing dependency lands. The write
path never rebuilds the document; it appends, relays, and acks, so a gapped
update costs the same as any other.

Serving is lossless too, like any Yjs server. `handle_sync_message` serves
full state, pending included, so a peer parks the same pending struct and
heals it the same way. Healing needs no special machinery: the missing
dependency is an update its sender still holds unacked, and at-least-once
retransmission delivers it. Only compaction excludes pending
(`compacted_state_update`), because folding a log must not freeze an
un-integrable struct into the base state.

The bundled `Y::Document` store handles all of this. If you write your own
store, keep two things in mind:

**1. Load losslessly, and tolerate duplicates.** `on_load` should return
state that preserves pending: `encode_state_as_update`, or a replay of the
raw append log. Don't compact with `compacted_state_update` while
`doc.pending?`; that strips the pending struct and the acked edit inside it.
(`Y::Document` quarantines pending rows for exactly this reason.) A lost ack
also means a client resends an update the store already has. Replay converges
anyway, because CRDT apply is idempotent, so deduping is optional. If log
size matters, dedup by content hash:

```ruby
class DocumentStore
  # append tolerates duplicates: a re-delivered update upserts to a no-op.
  def append(key, update)
    Revision.upsert({ doc_key: key, update_hash: Digest::SHA256.hexdigest(update), update: update },
                    unique_by: %i[doc_key update_hash])
  end

  # load is lossless: replay the raw log so a pending struct is preserved and
  # heals when its dependency arrives.
  def load(key)
    updates = Revision.where(doc_key: key).order(:id).pluck(:update)
    return nil if updates.empty?

    doc = Y::Doc.new
    updates.each { |u| doc.apply_update(u) }
    doc.encode_state_as_update # lossless: keeps pending
  end

  # optional compaction: only when there is no open gap, or you would drop it.
  def compact(key)
    doc = Y::Doc.new
    Revision.where(doc_key: key).order(:id).pluck(:update).each { |u| doc.apply_update(u) }
    return if doc.pending? # a gap is open; compacting now would drop it
    # ... replace the log with a single revision holding doc.compacted_state_update ...
  end
end
```

**2. Watch for gaps that never heal.** An open gap is quiet: the edit sits
as pending, invisible in the document, until its dependency arrives. Normally
that resolves itself. The sender retransmits the missing update until it is
acked, and every join or reconnect handshake has the client send everything
the server hasn't integrated, so any client holding the dependency supplies
it just by connecting. The gap worth alerting on is one no live client can
supply, and that is what the `on_gap` hook surfaces. It fires with the
document key whenever a document is loaded to serve state and a gap is still
open. Use it to emit a metric (a pending-document count, or the age of the
oldest open gap) so a stuck gap is visible. Gaps are also logged at `info`,
and errors raised in the hook are swallowed so observability can never break
frame handling.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_gap { |key| StatsD.increment("yrby.gap", tags: ["doc:#{key}"]) }
end
```

#### Multi-process deployments

Most Rails apps run several processes, and any of them might serve a given document. 
Two pieces keep them in step.

Broadcasts cross processes through the Action Cable adapter, so it needs to something
like `redis` or `solid_cable`, not `async`. With that in place, a change
on one process reaches clients on all of them.

Every process rebuilds document state from the durable store through `on_load`.
Because changes are recorded before broadcast, record-before-distribute holds
across processes: whichever process receives a change records it to the shared
store before anyone, anywhere, sees it.

`bun multiprocess.mjs` in the demo runs clients across two processes and checks
convergence, fresh reads on both, presence across processes, and one shared log.

##### AnyCable

`yrby` fully supports AnyCable.

The demo checks this against a real anycable-go + RPC server
(`frontend/anycable_probe.mjs`, `anycable_concurrent.mjs`): liveness, the
yrby client provider, cross-process reads, and concurrent convergence.

##### Demo

[`examples/actioncable-demo`](examples/actioncable-demo) is a full Rails + Tiptap
app using the yrby provider, with end-to-end tests.

#### Record Before Distribute

Every document change is handed to the `on_change` handler before broadcasting.
It is up to you to durably record it:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  # ...

  on_change do |key, update|
    # Synchronous, durable write. `update` is the exact CRDT delta.
    AuditLog.append!(key, update)   # raise to REJECT the change
  end

  # ...
end
```

If the recorder raises (say the store is down), the change is rejected: not
applied, not sent to anyone. The cost is a synchronous durable write on the path
of every change. There's no in-gem per-document lock; concurrent writes to one
document can both record (at-least-once), and since CRDT apply is idempotent a
duplicate record replays to the same document.

The demo wires `on_change` to a durable Postgres-backed log by default, and checks
end to end that the log alone rebuilds the document.

#### Ephemeral documents (no database)

`on_load` and `on_change` are plain blocks, and nothing requires them to touch
a database. For documents that don't need to outlive their session (a
scratchpad, live form state, a draft you only persist on submit) the store
can be connection state that travels with each request:

```ruby
class ScratchpadChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load { |key| @doc_state }

  on_change do |key, update|
    doc = Y::Doc.new
    doc.apply_update(@doc_state) if @doc_state
    doc.apply_update(update)
    @doc_state = doc.compacted_state_update
  end

  def subscribed    = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])

  private

  # The scratchpad lives on this connection — every subscriber gets their own.
  def authorized?(_key) = true
end
```

On AnyCable the channel object doesn't survive between messages, so an
instance variable won't hold. Declare the store as channel state instead
(`state_attr_accessor` comes from anycable-rails) and Base64 it, because that
state is serialized as JSON into each RPC exchange with `anycable-go`:

```ruby
class ScratchpadChannel < ApplicationCable::Channel
  include Y::ActionCable

  state_attr_accessor :doc_state

  on_load { |key| doc_state && Base64.strict_decode64(doc_state) }

  on_change do |key, update|
    doc = Y::Doc.new
    doc.apply_update(Base64.strict_decode64(doc_state)) if doc_state
    doc.apply_update(update)
    self.doc_state = Base64.strict_encode64(doc.compacted_state_update)
  end

  def subscribed    = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])

  private

  def authorized?(_key) = true # per-connection scratchpad, see above
end
```

Both hooks run in the channel instance (`instance_exec`), so they can use
anything the channel can, and `sync_receive` rebuilds the document from
`on_load` on every update, which is what lets the store live on the
connection. On Action Cable the channel instance lasts as long as the
connection, so an instance variable is the whole store. Merging into
`compacted_state_update` keeps it one blob instead of a growing update log.

The store is per connection, which shapes what this fits. A single writer gets
the full delivery contract with no database anywhere. With several people
editing at once, one client's update can depend on edits its own connection
has never seen; that update records as pending, and the next handshake with
that client (which always holds the full document) supplies the missing state
and heals it. The document still converges; heavy concurrent editing just
parks more pending between handshakes than a shared store would. On
AnyCable, keep the payload in mind too: the blob travels with every message,
so that variant suits small documents, not long manuscripts.

Durability is the connection plus the browsers. A reconnecting client re-seeds
an empty server through the ordinary sync handshake, so the document survives
server restarts as long as some client still has it. For ephemeral documents
shared across clients on a single-process deployment, the same two hooks over
a class-level `Concurrent::Map` work instead; that version stops being
coherent the moment you scale past one process.

#### Reliable delivery (acks)

yrby document delivery is ack-tracked. Browser document updates carry an
`"id"`, and the server replies `{ "ack": <id> }` once `on_change` has
successfully fired. Every decodable document update is recorded and acked,
including one that arrives out of order.

```
client -> server   { "update": "<base64 update>", "id": 42 }
server -> client   { "ack": 42 }     # update accepted; safe to forget
```

`yrby-client`'s `ActionCableProvider` handles this automatically. It keeps
the unacknowledged local document tail in a queue and sends the merged tail as a
single causally-complete delta. The id is the highest sequence in the batch, so
one `{ ack: id }` cumulatively confirms everything up to it. Because CRDT apply
is idempotent, a resend that already landed is a harmless no-op that just
re-acks. Awareness stays ephemeral and is not acked.

Presence (cursors, selections) is owned by the browser clients; the server
never sets or holds presence state, it only relays awareness frames opaquely.
See `yrby-client` for the client-side awareness API.

## Thread Safety

A `Doc` is safe to share across Ruby threads, used concurrently from Puma
workers, ActionCable connection threads, or background jobs without external
locking.

`test/thread_safety_test.rb` runs shared docs, the full sync handshake, and
fan-in sync across 8 threads at once, and checks the interleaving doesn't change
convergence.

### Parallelism (GVL release)

Every method that does real CRDT work (applying updates, encoding state,
handling sync messages) releases Ruby's Global VM Lock
(`rb_thread_call_without_gvl`) while the native code runs. That buys two things.

CRDT work runs in parallel across Ruby threads on MRI, not just
JRuby/TruffleRuby. `bench/parallelism_bench.rb` measures over 2x wall-clock
speedup applying a ~900 KB update concurrently; native code that held the GVL
couldn't beat serial time.

A slow operation also can't stall the VM. A thread applying a large update holds
the doc's write lock without holding the GVL, so other Ruby threads keep running
instead of queuing behind it.

Each method has the same shape: copy Ruby byte strings first, drop the GVL, do
the yrs work while taking and releasing native locks entirely inside the
closure, take the GVL back, then build Ruby objects. No Ruby API is touched
without the GVL, and no native lock is held while reacquiring it, so the lock
order can't deadlock. Panics in native code are caught and re-raised as Ruby
exceptions.

## Message Type Constants

```ruby
Y::MSG_SYNC            # 0 - Document sync messages
Y::MSG_AWARENESS       # 1 - User presence data

Y::MSG_SYNC_STEP1      # 0 - State vector request
Y::MSG_SYNC_STEP2      # 1 - Update response
Y::MSG_SYNC_UPDATE     # 2 - Incremental update
```

## Sync Flow

```
Client A                          Server
   |                                  |
   |-------- connect() ------------->|
   |  (SyncStep1 + Awareness)        |
   |                                  |
   |<--- handle_sync_message resp ---|
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
