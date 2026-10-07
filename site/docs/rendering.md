# Server-side rendering

These classes turn a collaborative document into HTML in Ruby, with no Node or
headless browser. Each one targets a specific editor and produces the same
HTML that editor would. `Y::Tiptap` renders Tiptap documents and builds on
`Y::ProseMirror`. `Y::Lexxy` renders [Lexxy](https://github.com/basecamp/lexxy)
documents and builds on `Y::Lexical`. For another editor built on ProseMirror
or Lexical, extend the base class with your own rules. Point a renderer at a
document from the other engine and it returns `nil`.

## Y::Tiptap

```ruby
tiptap = Y::Tiptap.new(doc)
tiptap.to_html            # the "default" fragment (Tiptap's default root)
tiptap.to_html("content") # or another XML root
```

The output matches Tiptap's own `getHTML()` byte for byte, and the tests check
it against a document captured from a real editor. It's modeled on
[`tiptap-php`](https://github.com/ueberdosis/tiptap-php). It understands both
naming styles, Tiptap's (`bulletList`, `bold`) and prosemirror-schema-basic's
(`bullet_list`, `strong`).

It covers paragraphs, headings, blockquotes, bullet, ordered, and task lists,
code blocks, links, images, mentions, details, hard breaks, horizontal rules,
tables, text styles (color and font family), and the rest of Tiptap's marks.
Tables come out as a plain `<table><tbody>`. The column widths that Tiptap's
editor adds on screen aren't included.

`Y::ProseMirror` covers core ProseMirror, meaning prosemirror-schema-basic and
the prosemirror-tables family. `Y::Tiptap` adds Tiptap's extra nodes (task
lists, mentions, and details) as a rule set, `Y::Tiptap::NODES`, written with
the same rules API shown below. The native renderer handles marks itself,
because node rules can't express how marks work. Marks have to nest in a fixed
order, `textStyle` needs CSS, and `code` can't combine with other marks.

## Y::Lexxy

```ruby
lexxy = Y::Lexxy.new(doc)
lexxy.to_html            # the "root" fragment (Lexical's default root name)
lexxy.to_html("notepad") # or another XML root
```

The HTML is the same as the `value` a `lexxy-editor` submits to Rails, and the
tests check it against a document captured from a real editor. Lexical itself
has no standard HTML output, because each editor sets up its own, so the class
is named after Lexxy. `Y::Lexical` covers core Lexical, and other Lexical
editors can extend it with their own rules.

It handles every node in Lexxy 1.0, which has the same nodes as 0.9.x: paragraphs, headings, every text
format and their combinations, links, the four list types with nesting,
blockquotes, code blocks, tabs and soft breaks, horizontal rules, tables with
header cells, image galleries, and ActionText attachments. Uploads and mentions
both come out as `<action-text-attachment>` elements, which Action Text knows
how to display. If you configured Lexxy with a different attachment tag name, the
renderer uses the tag stored on each node. An upload that's still in progress
renders nothing.

If either renderer meets a node it doesn't know, it still outputs the node's
text and nested blocks.

## Custom nodes and marks

The built-in rules cover the nodes that come with Tiptap and Lexxy. Apps often add their own
node types, and both renderers take rules for those. Your rules are checked
first, so a rule can add a new node type or change how a built-in one renders.

Register rules in a block, with one `rules.node` call per type. The simplest
kind names a tag, its attributes, and what goes inside, and the native
renderer does the rest.

```ruby
tiptap = Y::Tiptap.new(doc) do |rules|
  rules.node "callout", tag: "aside",
                        attrs: { "class" => ["callout callout--", :kind] },
                        contains: :blocks
end
```

`tag` names the element. Each value in `attrs` is a template. A string is used
as is, a symbol reads that attribute from the node, and an array joins a mix of
the two. An attribute that comes out empty is left off. `text` takes
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
element and block children by type, in document order. Use it for questions
the attributes can't answer, like how many images a gallery has or whether a
list item has a nested list. The renderer inserts whatever
the block returns without escaping it, so escape any values you interpolate.
`ERB::Util.html_escape` works, but it also escapes apostrophes. If your output
has to match the editor's exactly, use `Y::RenderRules.escape_text` and
`Y::RenderRules.escape_attr`, which escape the same characters the renderers
do. To set the content mode for a block rule, pass both:
`rules.node "embed", contains: :blocks do |node| ... end`.

Blocks don't run while the document is locked. The renderer does its native
pass first, in one read transaction with the GVL released, then runs your
blocks and inserts what they return. So a block can safely read the same doc,
write to it, or query the database.

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

## Overriding a built-in rule

This rule renders Lexxy uploads as plain images, in place of the
`<action-text-attachment>` elements the built-in rule outputs.

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
