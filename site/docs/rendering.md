# Server-side rendering

The renderers turn a collaborative document into HTML on the server, without
Node or a headless editor. Each renderer targets one editor and produces the
same HTML as that editor's own serializer. `Y::Tiptap` renders ProseMirror
documents and is built on `Y::ProseMirror`. `Y::Lexxy` renders documents from
the [Lexxy](https://github.com/basecamp/lexxy) editor and is built on
`Y::Lexical`. To support another editor on the same engine, extend one of those
base classes with rules. Each renderer returns `nil` for a root written by the
other engine.

## Y::Tiptap

```ruby
tiptap = Y::Tiptap.new(doc)
tiptap.to_html            # the "default" fragment (Tiptap's default root)
tiptap.to_html("content") # or another XML root
```

The output matches Tiptap's own `getHTML()` byte for byte. The tests compare it
against a document captured from a real editor. The implementation follows
[`tiptap-php`](https://github.com/ueberdosis/tiptap-php). It reads both naming
styles editors use: Tiptap's `bulletList` and `bold`, and
prosemirror-schema-basic's `bullet_list` and `strong`.

It covers paragraphs, headings, blockquotes, bullet, ordered, and task lists,
code blocks, links, images, mentions, details, hard breaks, horizontal rules,
tables, text styles (color and font family), and the rest of Tiptap's marks.
Tables render as a plain `<table><tbody>`, without the column-width styling
that Tiptap's editor view adds.

`Y::ProseMirror` handles core ProseMirror: prosemirror-schema-basic plus the
prosemirror-tables family. `Y::Tiptap` adds Tiptap's extension nodes (task
lists, mentions, and the details family) as a rule set, `Y::Tiptap::NODES`,
written with the rules API described below. Marks are handled in the base
class. Getting marks right means nesting them in the right order, writing the
CSS for `textStyle`, and keeping `code` from combining with other marks. Node
rules can't express that, so the native renderer does it.

## Y::Lexxy

```ruby
lexxy = Y::Lexxy.new(doc)
lexxy.to_html            # the "root" fragment (Lexical's default root name)
lexxy.to_html("notepad") # or another XML root
```

The HTML is the same as the `value` a `lexxy-editor` submits to Rails. The
tests compare it against a document captured from a real editor. Stock Lexical
has no standard serializer, because every editor configures its own. That's why
the class is named after the editor. `Y::Lexical` covers core Lexical, and other
Lexical editors can extend it with their own rules.

It handles every node in the Lexxy 0.9.x set: paragraphs, headings, every text
format and their combinations, links, the four list types with nesting,
blockquotes, code blocks, tabs and soft breaks, horizontal rules, tables with
header cells, image galleries, and ActionText attachments. Uploads and mentions
both render as `<action-text-attachment>` elements, which ActionText can render
again. If you configured Lexxy with a different attachment tag name, the
renderer uses the tag stored on each node. An upload that's still in progress
renders nothing.

In both renderers, an unknown node still renders its text and nested blocks as
readable markup.

## Custom nodes and marks

The built-in schemas match what Tiptap and Lexxy ship. Apps often add their own
node types, and both renderers accept rules for them. The renderer checks your
rules before its built-in schema, so a rule can add a node type or change how a
built-in one renders.

You register rules in a block, with one `rules.node` call per type. A
declarative rule describes the markup as a tag, attributes, and a content mode,
and the native renderer produces it.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "callout", tag: "aside",
                        attrs: { "class" => ["callout callout--", :kind] },
                        contains: :blocks
end
```

`tag` names the element. Each value in `attrs` is a template. A string is used
as is, a symbol reads that attribute from the node, and an array joins a mix of
the two. An attribute that resolves to an empty value is left out. `text` takes
the same kind of template and outputs it as text content. `contains` says what
the node holds. Use `:inline` for formatted text, `:blocks` for child block
nodes, or `:none` for a node with no content. `:inline` is the default.
`void: true` leaves off the closing tag.

## Finding a document's node types

Editors store types and attributes under names that are hard to guess. Rhino's
strike mark is `rhino-strike`, and Lexical prefixes its own properties with
`__`. To see the real names, create a document in your editor that uses your
custom node, then ask the renderer:

```ruby
Y::Tiptap.new(doc).node_types
# => { "callout"   => { "count" => 2, "attrs" => ["kind"],
#                       "children" => ["paragraph"], "text" => false,
#                       "handled" => nil },
#      "paragraph" => { ..., "handled" => "builtin" } }
```

A `handled` of `nil` means the type still needs a rule. `attrs` lists the
stored attribute names your templates and blocks can read. `children` and
`text` tell you which `contains:` to use. Child block types mean `:blocks`, and
text means `:inline`.

## Blocks

When a declarative rule can't describe the markup, give the node a block.

```ruby
lexical = Y::Lexical.new(doc) do |rules|
  rules.node "video_embed" do |node|
    src = ERB::Util.html_escape(node.attrs["__src"])
    %(<video controls src="#{src}"></video>)
  end
end
```

The block receives the node's type and stored attributes. `node.content` is the
node's children, already rendered to HTML. `node.child_types` lists the node's
element and block children by type, in document order. Use it for structural
questions the attributes can't answer, such as how many images a gallery holds
or whether a list item contains a nested list. The renderer inserts whatever
the block returns without escaping it, so escape any values you interpolate.
`ERB::Util.html_escape` works, but it also escapes apostrophes. If your output
has to match the editor's exactly, use `Y::RenderRules.escape_text` and
`Y::RenderRules.escape_attr`, which escape the same characters the renderers
do. To set the content mode for a block rule, pass both:
`rules.node "embed", contains: :blocks do |node| ... end`.

Blocks never run while the document is locked. The renderer finishes its pass
first, inside one read transaction with the GVL released. Then it runs the
blocks and inserts their output. So a block can read the same doc, write to it,
or query the database.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "mention" do |node|
    user = User.find_by(id: node.attrs["id"])
    next "<span>@unknown</span>" unless user

    %(<a class="mention" href="/users/#{user.id}">@#{ERB::Util.html_escape(user.handle)}</a>)
  end
end
```

`Y::Lexxy` and `Y::Tiptap` use this same API for their own schemas. Their
simple nodes are declarative hashes, and every node that needs logic is a plain
Ruby method mapped by node type.

## Custom marks

`Y::ProseMirror` and `Y::Tiptap` also accept custom marks.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.mark "comment", tag: "span", attrs: { "data-comment-id" => :id }
end
```

Symbols read from the mark's own attributes. A custom mark wraps outside every
built-in mark. When several custom marks cover the same text, they nest in
alphabetical order by name. A rule for a built-in mark name like `"bold"`
replaces that mark's markup.

## Overriding a shipped rule

This rule renders Lexxy uploads as image markup. The shipped rule outputs the
`<action-text-attachment>` elements that ActionText renders.

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

This one drops empty paragraphs. It can check for them because `node.content`
is already rendered when the block runs.

```ruby
lexical = Y::Lexical.new(doc) do |rules|
  rules.node "paragraph" do |node|
    node.content.empty? ? "" : "<p>#{node.content}</p>"
  end
end
```
