# Experimental APIs

These APIs are new. They may change in any minor release, and they aren't
covered by yrby's usual compatibility promise. Everything else is in the
[README](../README.md).

`require "y/action_cable/client"` and `require "y/agent"` print a warning in
Ruby's `:experimental` category. `Warning[:experimental] = false` turns it off.

- [Y::Map (live shared maps)](#ymap-live-shared-maps)
- [Y::Array (live shared lists)](#yarray-live-shared-lists)
- [Y::Text (live shared text)](#ytext-live-shared-text)
- [Writing rich text from Ruby](#writing-rich-text-from-ruby)
- [Anchors: a block's identity as a value](#anchors-a-blocks-identity-as-a-value)
- [Streaming into a document](#streaming-into-a-document)
- [Editing a document from Ruby](#editing-a-document-from-ruby)
- [Joining a document from a Ruby process](#joining-a-document-from-a-ruby-process)
- [Agents](#agents)

## Y::Map (live shared maps)

`Doc#get_map` returns a live handle to a `Y.Map` root: reading it reflects the
current document, and writing it mutates the CRDT (so the change syncs to every
peer). Handles carry the same thread-safety guarantees as `Doc`: every operation
runs with the GVL released and holds no lock across the boundary.

```ruby
map = doc.get_map("state")   # root map, created if absent

# Write: primitives, arrays, and (nested) hashes
map["title"]  = "Dashboard"
map["count"]  = 3
map["tags"]   = %w[a b c]
map["user"]   = { "name" => "Ada", "role" => "eng" }  # nested Y.Map

# Read: a snapshot value (nested map/array come back as Hash/Array)
map["title"]           # => "Dashboard"
map.to_h               # => { "title" => "Dashboard", "count" => 3, ... }
map.keys               # => ["title", "count", "tags", "user"]
map.size               # => 4
map.key?("title")      # => true
map.each { |k, v| puts "#{k}: #{v}" }

# A live handle to a nested map; mutating it mutates the document
user = map.get_map("user")   # => Y::Map (or nil if absent / not a map)
user["name"] = "Grace"       # doc now has state.user.name == "Grace"

# Delete
map.delete("count")    # => 3 (the previous value)
map.clear
```

A handle holds the identity of the shared type it points at, not a path to
it, and looks the type up again on every operation. A raw CRDT pointer never
leaves the transaction that found it, since another thread can delete the
type and free it as soon as that transaction ends. A nested handle stays on
its map as keys and elements change around it. Once that map is deleted,
reads return nothing and writes raise `Y::Error`.

## Y::Array (live shared lists)

`Doc#get_array` returns a live handle to a `Y.Array` root. The method that
matters is `get_map`: a list of records is the shape most collaborative state
has, and a handle addressed by index is what lets you edit one in place.

```ruby
plan = doc.get_array("plan")   # root array, created if absent

plan.push({ "text" => "Find the posts", "status" => "pending" })
plan << { "text" => "Draft an outline", "status" => "pending" }
plan.insert(1, { "text" => "Summarize them", "status" => "pending" })

plan[0]                        # => { "text" => "Find the posts", ... } (a snapshot)
plan.size                      # => 3
plan.to_a                      # => the whole list, as plain Ruby
plan.each { |step| puts step["text"] }

# A live handle to a record stored in the list. Writing it writes the document.
step = plan.get_map(0)         # => Y::Map (or nil if that element is not a map)
step["status"] = "done"        # every peer sees the status change

plan.delete_at(-1)             # => the removed value
plan.clear
```

Indexes work as Ruby's do: a negative index counts from the end (so
`insert(-1, value)` appends), and an index outside the array reads as `nil`.
The handle `get_map` returns stays on its record when others are inserted or
removed around it.

## Y::Text (live shared text)

`Doc#get_text` returns a live handle to a `Y.Text` root. Appending is a CRDT
insert rather than a whole-document write, so a person typing in the same text
while a server-side writer appends keeps their edit, and so does the writer.

```ruby
body = doc.get_text("body")

body.push("The agent wrote ")   # append; the hot path when streaming
body << "this sentence."
body.insert(0, "Note: ")        # insert at an index
body.delete(0, 6)               # remove a range

body.to_s                       # => "The agent wrote this sentence."
body.length
body.empty?
body.clear
```

Indexes are characters, as `String#index` counts them, whatever the text
holds: accents, emoji, any script. `relative_position(index)` gives a caret
that keeps its place as people edit, and `index_at(position)` says where it is
now, for this text's own positions and for a person's caret from awareness.

Every handle can reach any nested shared type: `get_map`, `get_array`, and
`get_text` exist on both `Y::Map` and `Y::Array`, so a text field inside a
record inside a list is directly addressable.

To make a nested text, use `set_text` on a map, or `push_text` or
`insert_text` on an array. Each one stores a new `Y.Text` and returns its
handle. A field held this way merges typing: two people who type in it at
once both keep their edit. `map["name"] = "Ada"` stores a plain string,
and the last write to it wins.

```ruby
form = doc.get_map("form")
name = form.set_text("name", "Ada")   # => Y::Text
name.push(" Lovelace")
form.get_text("name").to_s            # => "Ada Lovelace"

plan = doc.get_array("plan")
plan.push_text("Draft an outline")    # => Y::Text
plan.insert_text(0, "Find the posts") # same index rules as insert
```

> **Naming note.** Inside `module Y`, `Array` means `Y::Array`. Code in that
> namespace that means the core class says `::Array`, and `Kernel.Array(...)`
> for the conversion method, the same way channels in `module Y` say
> `::ActionCable`.

## Writing rich text from Ruby

Rich-text editors built on Yjs keep their document in `XmlText` nodes.
`Doc#get_xml_text` returns a live `Y::XmlText` handle with the operations that
shape needs: `insert` a string, `insert_embed` a JSON value, `set_attribute`,
and `push_xml_text(attributes, content)` to append a nested block and get its
handle. `content` is written into the block in the same transaction: an Array
of Strings (text), Hashes (embeds), and `[attributes, content]` pairs (nested
blocks). `append(content)` and `replace(content)` write content into a block
the same way. `xml_text(n)` returns a handle to the `n`-th nested block, or
nil. A block handle stays on its block while people add and remove blocks
around it. Indexes inside a block are characters, with each embed counting as
one.

`Y::Lexical` builds Lexical's exact node shape on top of that, so what Ruby
appends renders the same as what a person typed and an open editor applies it
as an ordinary remote edit. Each helper writes its block in one transaction,
so a peer or another thread never sees a block without its text:

```ruby
doc = Y::Doc.new
Y::Lexical.append_heading(doc, "Agent review", tag: "h2")
Y::Lexical.append_paragraph(doc, "Read 82 words. One suggestion: name who signs off.")
Y::Lexxy.new(doc).to_html("root")
# => "<h2>Agent review</h2><p>Read 82 words. One suggestion: name who signs off.</p>"
```

`append_list(doc, items, ordered:)` appends a bulleted or numbered list. Call
it on the flavor that matches the editor: `Y::Lexxy.append_list` writes
Lexxy's own list item type, `Y::Lexical.append_list` the standard one.

Text can be formatted. Anywhere a helper takes text it also takes runs, an
array of strings and hashes: `{ text: "bold", bold: true }`, and likewise
`italic:`, `strikethrough:`, `underline:`, `code:`, or `link: "https://…"`.
String keys work too, as parsed JSON has them.
`append_quote` and `append_code(doc, code, language:)` add quotes and code
blocks. `append_markdown(doc, text)` takes the subset of Markdown a model
writes (headings, lists, quotes, fenced code, and inline formatting and
links) and appends it as blocks. A link must be `http`, `https`, `mailto`,
`sms`, `tel`, or a path; a `javascript:` link stays plain text. The renderers
also refuse one stored some other way: `Y::Lexical` sends it to
`about:blank`, as Lexical's link node does, and `Y::ProseMirror` empties its
`href`, as Tiptap's link mark does.

A block handle's `text` is what it says, markers skipped and nested blocks
joined by newlines. The document can be edited in place, not only appended
to. A block handle has `delete(index, length)` and `clear`; a parent has
`insert_xml_text(at, attributes, content)` and `delete_xml_text(at)`. The helpers
`insert_paragraph(doc, at, runs)`, `replace_runs(block, runs)`, and
`delete_block(doc, at)` cover the common moves. `append_text(block, text)`
adds text at the end of a block; Lexical drops text that doesn't follow a
text node, so after a link it starts a new one.

`apply_update_changes(update, root)` applies an update and returns the
ordinals of the top-level blocks it touched: a block edited (however deep),
added, or removed. Ordinals count blocks as `xml_text(n)` does, so a divider
or an image doesn't shift them. A process following a document reacts to the
part that changed instead of diffing the text.

To put a change into a record's document, write it inside
`collaborative_document(:body).edit` (see "Editing a document from Ruby"). A
Ruby-written paragraph and a typed one render byte for byte the same.

A caret is a Yjs relative position, and `relative_position(index)` builds
one: the `{type, tname, item, assoc}` hash editors put in awareness as
`anchorPos` and `focusPos`. Ids are global, so a position built from a
replayed document resolves in every open editor. Put it in the presence
state and people see the caret move.

## Anchors: a block's identity as a value

A live handle stays on its block, but it lives in one process. An anchor is
the same identity as a plain value that serializes to JSON, so a job can store
it and pick the block up later. `XmlText#anchor` returns a `Y::Anchor`: a
relative position that names the block itself, plus the root's name.
`Doc#block_at(anchor)` returns the block's ordinal now, or nil once it is gone,
and `Doc#find(anchor)` returns a live handle to it.

```ruby
block = Y::Lexical.append_paragraph(doc, "Verify the canary rollout.")
anchor = block.anchor
doc.get_xml_text("root").insert_xml_text(0, Y::Lexical::PARAGRAPH_ATTRIBUTES)
doc.block_at(anchor)                          # => 1
Y::Lexical.append_text(doc.find(anchor), " Owner: SRE.")
Y::Anchor.from_json(anchor.to_json) == anchor # => true
```

`XmlText#attributes` returns a block's attributes (`__type`, `__tag`, and the
rest), what a process keeps to put a block back the way it was.

## Streaming into a document

A process that types into a document over time, such as a job writing what
a model produces, keeps one `Y::Doc` for the whole stream and sends each piece
as its own update. `Doc#edit` runs a block that writes to the document and
returns an update with every local write no edit has returned yet, or nil
when there's nothing to send. The document keeps every local write until an
edit returns it, so a write made outside the block, or in a block that
raised, comes with the next update. Send every update an edit returns: an
edit in a thread the block didn't start, such as a pool thread, takes the
block's earlier writes too. An update applied from a peer is never in it,
and doesn't wait for the block:

```ruby
doc = Y::Doc.new
paragraph = Y::Lexical.append_paragraph(doc, "")
%w[one two three].each do |word|
  update = doc.edit { Y::Lexical.append_text(paragraph, "#{word} ") }
  # save `update`, then Y::ActionCable.broadcast(key, update)
end
```

Each update is about its chunk, not the document, so open editors show the
words appearing. Put the block's end position in the presence state and the
caret follows what it writes.

## Editing a document from Ruby

A job, a console, or a controller edits a record's document with `edit`. It
loads the current document, yields it, records what the block changed in the
document's rows, and broadcasts the update so open editors apply it. It
returns the update, or nil when the block wrote nothing.

```ruby
post.collaborative_document(:body).edit do |doc|
  Y::Lexxy.append_paragraph(doc, "Reviewed by ops.")
end
```

The edit is a CRDT update like a browser's, so a person typing at the same
moment keeps their change and so does the job. An encrypted document is
edited through its encrypted rows.

`Y::ActionCable.broadcast(key, update)` sends an update you already recorded
to a document's subscribers, for code that records updates itself.

## Joining a document from a Ruby process

`Y::ActionCable::Client` joins a document the way a browser does: over the
cable's websocket, as a subscriber of the document channel, with a grant. The
server records, acks, and relays its edits like anyone else's, and it applies
everyone else's edits to its own `Y::Doc`. An agent, a worker, or a script
runs as one, outside the web process.

```rb
# Gemfile: gem "async-websocket"
require "y/action_cable/client"

client = Y::ActionCable::Client.new(
  "wss://example.com/cable",
  params: { grant: post.collaborative_document(:body).grant, name: "body" }
)
client.on_update { |update, doc, changed| } # changed: ordinals of the blocks it touched
client.subscribe                               # returns once the document has loaded
client.presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }
client.edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewed.") }
client.unsubscribe                             # waits for acks, clears presence, closes
```

The grant gets the client into the document. Before that,
`ApplicationCable::Connection` has to accept the socket. The client sends the
URL's own origin as its `Origin`, which Action Cable accepts as same-origin.
Pass `headers:` when the connection needs more:

- An `"Origin"` when the process reaches the cable at another address than
  the site's, such as an internal URL.
- A token that `connect` checks, when it rejects sockets without a
  logged-in user. The process has no cookie, and `current_user` in the
  channel is whoever `connect` says it is.

A connection the server refuses, or a subscription it rejects, raises
`Y::Error` from `subscribe`.

`edit` sends what its block changed. A remote update waits until the block
returns, so the update holds only this client's edit. Every update carries an
id and is resent until the server acks it, and a dropped socket reconnects
with backoff. `presence=` shows the client in the editor's roster and is
renewed every 15 seconds, since peers drop presence they haven't heard from in
30.

The client runs as a task of the caller's reactor when there is one (Falcon,
an `Async` block) and in a thread of its own otherwise (Puma, a job, a
script). Callbacks run on that reactor, so keep them short.

`Y::Awareness` is the presence state underneath: `set_local_state(json)`
returns the frame to send, `apply_update(frame)` reads another client's, and
`states` returns every client's state by client id. `Doc#client_id` is the id
a document writes its edits under, and a presence for the same writer uses it
so editors tie a caret to its author.

## Agents

`Y::Agent` runs a Ruby process as a participant in a document: it joins with
a grant, shows up among the people editing, hears what they write, and
leaves when they do. Subclass it, and run it from a job.

```rb
require "y/agent"

class Reviewer < Y::Agent
  def presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }

  def joined
    edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewing.") }
  end

  def changed(blocks) # ordinals of the top-level blocks people changed
    reply = ReviewModel.call(doc.read_xml("root").to_s)
    edit { |doc| Y::Lexxy.append_paragraph(doc, reply) }
    leave if reply.include?("Looks good")
  end
end

class ReviewJob < ApplicationJob
  def perform(post)
    Reviewer.run(post.collaborative_document(:body), url: "wss://example.com/cable")
  end
end
```

An agent overrides three methods, and each has a default that does nothing:

- `presence` is how it shows up in the editor's roster, such as
  `{ "user" => { "name" => "Reviewer" } }`. Without one, it doesn't.
  `self.presence =` changes it while the agent stays, to show what it's
  working on or put its caret somewhere.
- `joined` runs once the document has loaded, and can write right away.
- `changed(blocks)` gets the blocks people changed once their typing has
  paused for a moment, or after five seconds of steady typing, and never
  the agent's own edits. The list is empty when the change was outside the
  root, such as to a map.

Inside them, `doc` is the agent's copy of the document, `edit` changes it and
sends the change, `people` lists who else is present, `document` is what
`run` was given, and `leave` ends the agent once the method returns.

The agent signs its own grant for the document, good for `max_stay:` plus a
minute. `url:` and `headers:` work as they do for `Y::ActionCable::Client`
above. Enqueue the job from code that has already checked the person may
edit the post, since the agent gets the same access.

`run` returns when the agent leaves. In a job it holds the job's thread for
that long, with the agent's connection on a reactor in that thread. Inside a
reactor (Falcon, an `Async` block) it runs as a task of that one. A job that
runs an agent holds a worker for as long as the agent stays, so give agents
their own queue.

The agent leaves when nobody else has been present for `idle:` seconds (120
by default), after `max_stay:` (two hours), or when it calls `leave`. People
already in the document show up only when their editor next renews its
presence, so the agent waits one renewal window, 15 seconds, before it
decides it is alone. It always clears its presence and unsubscribes on the
way out.

An error in `joined` or `changed` ends the agent. It leaves, and the error
raises out of `run`, so a job retries it as it would any other error.
Rescue in the method to carry on instead.

One agent works on a document at a time. Pass `as:` to allow one per person
instead, such as `as: person` when each person can bring their own agent. A
record is named by its GlobalID. The lock is in `Rails.cache` by default,
so it holds across processes when the cache is shared. Pass `lock:` for
another `ActiveSupport::Cache` store. A thread renews it while
the agent stays, so a slow model call doesn't let it lapse. `run` returns
`:busy` without joining when another agent holds the document, and `:left`
otherwise. Cache stores can't compare and set in one step, so a process that
stalls for over a minute can lose the lock and briefly overlap the agent that
took over. Its writes raise `Y::Error` from then on.

The first argument is usually `record.collaborative_document(:name)`, which
names its own grant and channel. Any object that responds to `key`, `name`,
`grant(expires_in:)`, and `channel` works. Pass `channel:` for an app's own
`Y::DocumentChannel` subclass.
