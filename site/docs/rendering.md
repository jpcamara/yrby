# Server-side rendering

The renderers turn a collaborative document into HTML on the server. No Node
process and no headless editor are involved. Each renderer is a class for one
specific editor, and it matches that editor's own serializer byte for byte.
`Y::Tiptap` renders ProseMirror documents and is built on `Y::ProseMirror`.
`Y::Lexxy` renders documents from the [Lexxy](https://github.com/basecamp/lexxy)
editor and is built on `Y::Lexical`. Those base classes are the extension
point: another editor on the same engine extends one of them with rules. Each
renderer returns `nil` for a root that belongs to the other schema.

## Y::Tiptap

```ruby
tiptap = Y::Tiptap.new(doc)
tiptap.to_html            # the "default" fragment (Tiptap's default root)
tiptap.to_html("content") # or another XML root
```

The output matches Tiptap's own `getHTML()`. The tests check that byte for byte
against a document captured from a real editor. The implementation follows
[`tiptap-php`](https://github.com/ueberdosis/tiptap-php), and it reads both
naming styles editors use: Tiptap's `bulletList` and `bold`, and
prosemirror-schema-basic's `bullet_list` and `strong`.

It covers paragraphs, headings, blockquotes, bullet, ordered, and task lists,
code blocks, links, images, mentions, details, hard breaks, horizontal rules,
tables, text styles (color and font family), and every text mark. A table
renders as a plain `<table><tbody>`. The column-width styling Tiptap's editor
view adds is left out.

The support comes in two layers. `Y::ProseMirror` handles core ProseMirror
natively: prosemirror-schema-basic plus the prosemirror-tables family. Tiptap's
extension nodes (task lists, mentions, the details family) are a rule set,
`Y::Tiptap::NODES`, written on the extension API described below. Marks live in
the base class. Mark rendering covers nesting order, the CSS on `textStyle`, and
the exclusivity of `code`, and it runs through the native text-run code that
node rules can't reach.

## Y::Lexxy

```ruby
lexxy = Y::Lexxy.new(doc)
lexxy.to_html            # the "root" fragment (Lexical's default root name)
lexxy.to_html("notepad") # or another XML root
```

The HTML is identical to what a `lexxy-editor` submits to Rails as its `value`.
The tests check that byte for byte against a document captured from a real
editor. Stock Lexical has no canonical serializer, because every editor
configures its own. That's why the class is named after the editor. `Y::Lexical`
is the core Lexical base, and any other Lexical editor extends it with rules.

It handles every node in the Lexxy 0.9.x set: paragraphs, headings, every text
format and their combinations, links, the four list types with nesting,
blockquotes, code blocks, tabs and soft breaks, horizontal rules, tables with
header cells, image galleries, and ActionText attachments. Uploads and mentions
both come out as `<action-text-attachment>` elements, which ActionText can
re-render.

In both renderers an unknown node keeps its content. Its text and nested blocks
still come out as readable markup.

## Custom nodes and marks

The built-in schemas match what Tiptap and Lexxy ship. Apps add their own node
types on top of that, and both renderers take rules for them. A rule is checked
before the built-in schema, so a rule can add a node type or change how a
built-in one renders.

Rules register in a block, one `rules.node` call per type. A declarative rule
describes the markup as a tag, attributes, and a content mode, and the renderer
emits it natively.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "callout", tag: "aside",
                        attrs: { "class" => ["callout callout--", :kind] },
                        contains: :blocks
end
```

`tag` names the element. The values in `attrs` are templates. A string is a
literal. A symbol reads that attribute off the node. An array concatenates a mix
of the two. An attribute that resolves to an empty value is left out. `text`
takes the same template form and emits literal text content. `contains` says
what lives inside the node: `:inline` for formatted text, `:blocks` for child
block nodes, or `:none` for a leaf. `:inline` is the default. `void: true` skips
the closing tag.

## Ask the document, don't guess

You don't have to guess any of those names or shapes. Editors store types and
attributes under names you wouldn't predict. Rhino's strike mark is
`rhino-strike`, and Lexical prefixes its own props with `__`. A real document
will tell you. Make one in your editor that uses your custom node, then:

```ruby
Y::Tiptap.new(doc).node_types
# => { "callout"   => { "count" => 2, "attrs" => ["kind"],
#                       "children" => ["paragraph"], "text" => false,
#                       "handled" => nil },
#      "paragraph" => { ..., "handled" => "builtin" } }
```

A `handled` of nil marks a type that still needs a rule. `attrs` lists the
stored attribute names your templates and blocks will read. `children` and
`text` tell you which `contains:` to pick: child block types mean `:blocks`, and
text means `:inline`.

## Blocks

When a declarative rule can't express the markup, give the node a block.

```ruby
lexical = Y::Lexical.new(doc) do |rules|
  rules.node "video_embed" do |node|
    src = ERB::Util.html_escape(node.attrs["__src"])
    %(<video controls src="#{src}"></video>)
  end
end
```

The block gets the node's type and its stored attributes. `node.content` is the
node's children, already rendered to HTML. `node.child_types` lists the node's
element and block children by type, in document order. That answers the
structural questions attributes don't: how many images a gallery holds, or
whether a list item has a nested list. Whatever the block returns is spliced
into the output as is. It's treated as trusted HTML, so escape any values you
interpolate. To set the content mode for a block, pass both:
`rules.node "embed", contains: :blocks do |node| ... end`.

Blocks never run while the document is locked. The render finishes first, inside
one read transaction with the GVL released. Then the blocks run and their output
is spliced in. That's why a block can safely read the same doc, write to it, or
hit the database.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "mention" do |node|
    user = User.find_by(id: node.attrs["id"])
    next "<span>@unknown</span>" unless user

    %(<a class="mention" href="/users/#{user.id}">@#{ERB::Util.html_escape(user.handle)}</a>)
  end
end
```

If no rule has a block, `to_html` skips the splicing step.

Blocks cover everything the declarative form can't. `Y::Lexxy` and `Y::Tiptap`
are built on this same API, so it has already been used for two complete editor
schemas. Their simple nodes are declarative hashes. Every node with logic is a
plain method mapped by node type, and the fixture tests hold that output
byte-identical to a live editor's.

## Custom marks

The ProseMirror side also takes custom marks.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.mark "comment", tag: "span", attrs: { "data-comment-id" => :id }
end
```

Symbols resolve against the mark's own attributes. A custom mark wraps outside
every built-in mark. When several custom marks land on one run, they nest
alphabetically by name. A rule for a built-in mark name like `"bold"` replaces
that mark's tag.

## Overriding a shipped rule

This rule renders Lexxy uploads as real image markup. The shipped rule emits the
`<action-text-attachment>` elements that ActionText re-renders:

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

This one drops the empty paragraphs an editor keeps around the cursor. It works
because `node.content` arrives already rendered:

```ruby
lexical = Y::Lexical.new(doc) do |rules|
  rules.node "paragraph" do |node|
    node.content.empty? ? "" : "<p>#{node.content}</p>"
  end
end
```
