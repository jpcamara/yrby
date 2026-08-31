# Server-side rendering

Schema-pinned renderers turn a collaborative document into HTML on the server,
with no Node process and no headless editor. Each is an editor-specific class,
byte-for-byte with that editor's own serializer, built on a core base that any
other editor extends with rules: `Y::Tiptap` on `Y::ProseMirror` for ProseMirror
documents, and `Y::Lexxy` (the [Lexxy](https://github.com/basecamp/lexxy)
editor) on `Y::Lexical`. Each returns `nil` for a root that belongs to the other
schema.

## Y::Tiptap

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
blocks, links, images, mentions, details, hard breaks, horizontal rules, tables,
text styles (color, font family), and every text mark. A table renders as
semantic `<table><tbody>`, without the column-width styling Tiptap's editor view
adds.

The support is layered. `Y::ProseMirror` covers core ProseMirror natively
(prosemirror-schema-basic plus the prosemirror-tables family) and Tiptap's
extension nodes — task lists, mentions, the details family — are `Y::Tiptap`'s
rule set (`Y::Tiptap::NODES`), built on the extension API below. Marks stay in
the base: mark rendering (nesting order, `textStyle` CSS, `code` exclusivity)
runs through native text-run machinery that node rules don't reach.

## Y::Lexxy

```ruby
lexxy = Y::Lexxy.new(doc)
lexxy.to_html            # the "root" fragment (Lexical's default root name)
lexxy.to_html("notepad") # or another XML root
```

The HTML is identical to what a `lexxy-editor` submits to Rails (its `value`),
checked byte-for-byte against a document captured from a real editor. Stock
Lexical has no canonical serializer — every editor configures its own — so the
editor-specific class carries the editor's name, and `Y::Lexical` is the
core-Lexical base for any other Lexical editor to extend with rules.

It handles the whole Lexxy 0.9.x node set: paragraphs, headings, every text
format and their combinations, links, the four list types and nesting,
blockquotes, code blocks, tabs and soft breaks, horizontal rules, tables with
header cells, image galleries, and ActionText attachments (uploads and mentions
both emit `<action-text-attachment>` elements that ActionText can re-render).

In both renderers an unknown node keeps its content: text and nested blocks fall
back to readable markup rather than disappearing.

## Custom nodes and marks

The built-in schemas are pinned to what Tiptap and Lexxy ship, but apps add
their own node types. Both renderers take rules for them. A rule is checked
before the built-in schema, so it can add a node type or replace how a built-in
renders.

Rules register in a block, one `rules.node` call per type. A declarative rule is
markup as data, rendered natively.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "callout", tag: "aside",
                        attrs: { "class" => ["callout callout--", :kind] },
                        contains: :blocks
end
```

`tag` names the element. `attrs` values are templates: a string is a literal, a
symbol reads that attribute off the node, an array concatenates both kinds; an
attribute that resolves empty is left out. `text` (same template form) emits
literal text content. `contains` declares what lives inside the node: `:inline`
(formatted text, the default), `:blocks` (child block nodes, a container), or
`:none` (a leaf). `void: true` skips the closing tag.

## Ask the document, don't guess

You don't have to guess any of those names or shapes. Editors store types and
attributes under names you'd never predict — Rhino's strike mark is
`rhino-strike`, Lexical prefixes its own props `__` — so ask a real document
instead. Make one in your editor using your custom node, then:

```ruby
Y::Tiptap.new(doc).node_types
# => { "callout"   => { "count" => 2, "attrs" => ["kind"],
#                       "children" => ["paragraph"], "text" => false,
#                       "handled" => nil },
#      "paragraph" => { ..., "handled" => "builtin" } }
```

`handled` nil marks the types that still need a rule; `attrs` are the stored
names your templates and blocks will read; `children` plus `text` is how you
pick `contains:` (child block types to `:blocks`; text to `:inline`).

## Blocks

When markup-as-data isn't enough, give the node a block.

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
whether a list item carries a nested list. Whatever the block returns is spliced
into the output as-is — it is trusted HTML, so escape any values you
interpolate. To set the content mode for a callback, give the node both:
`rules.node "embed", contains: :blocks do |node| ... end`.

Callbacks never run while the document is locked. The render finishes first
(inside one read transaction, GVL released), then the blocks run and their
output is spliced in, so a callback can safely read or even write the same doc,
or hit the database.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "mention" do |node|
    user = User.find_by(id: node.attrs["id"])
    next "<span>@unknown</span>" unless user

    %(<a class="mention" href="/users/#{user.id}">@#{ERB::Util.html_escape(user.handle)}</a>)
  end
end
```

With no callback rules, `to_html` skips the splicing entirely.

Blocks are the escape hatch for everything the declarative form can't say, and
they are proven sufficient: `Y::Lexxy` and `Y::Tiptap` are themselves built on
this API. Simple nodes are declarative hashes; everything with logic is a plain
method mapped by node type, and the fixture tests hold their output
byte-identical to a live editor's.

## Custom marks

The ProseMirror side also takes custom marks.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.mark "comment", tag: "span", attrs: { "data-comment-id" => :id }
end
```

Symbol refs resolve against the mark's own attributes. A custom mark wraps
outside every built-in mark; several on one run nest alphabetically. A rule for
a built-in mark name (`"bold"`) replaces its built-in tag.

## Overriding a shipped rule

Rendering Lexxy uploads as real image markup instead of the
`<action-text-attachment>` elements ActionText re-renders:

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

Or dropping the empty paragraphs an editor keeps around the cursor, since
`node.content` arrives already rendered:

```ruby
lexical = Y::Lexical.new(doc) do |rules|
  rules.node "paragraph" do |node|
    node.content.empty? ? "" : "<p>#{node.content}</p>"
  end
end
```
