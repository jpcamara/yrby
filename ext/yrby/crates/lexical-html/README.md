# lexical-yjs-html

Renders the Yjs representation of a [Lexical](https://lexical.dev) document
to HTML, using [yrs](https://crates.io/crates/yrs). Covers core Lexical:
paragraphs, headings, quotes, code blocks, lists, tables, links, and the
full text-format model. The tests pin the output byte-for-byte against
fixtures captured from a live editor.

## Usage

```toml
[dependencies]
lexical-yjs-html = "0.1"
yrs = { version = "0.27", features = ["sync"] }
```

The input is a Yjs update: bytes from a durable store, a provider, or
`Y.encodeStateAsUpdate` in the browser.

```rust,no_run
use yrs::updates::decoder::Decode;
use yrs::{Doc, ReadTxn, Transact, Update};

let update_bytes: Vec<u8> = std::fs::read("document.bin").unwrap();

let doc = Doc::new();
doc.transact_mut()
    .apply_update(Update::decode_v1(&update_bytes).unwrap())
    .unwrap();

let txn = doc.transact();
let fragment = txn.get_xml_fragment("root").expect("Lexical's default root");
let html = lexical_yjs_html::render(&txn, &fragment);
// => Some("<h1>Heading One</h1><p>…</p>") — or None if the fragment
//    isn't Lexical-shaped (e.g. a ProseMirror document).
```

An editor may hold several fragments under one doc; pass whichever root
name your editor binds. `render` returns `None` when the fragment's shape
is not Lexical's.

## Declarative rules

A rule describes how a node type the built-in schema does not know should
render: a tag, attribute templates, and a content slot. Declarative rules
render inside the document transaction with no callback:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use lexical_yjs_html::{flatten, render_segments, Rules};

let rules = Rules::parse(
    r#"{
      "nodes": {
        "callout": {
          "tag": "aside",
          "attrs": [["class", [{"lit": "callout callout--"}, {"ref": "kind"}]]],
          "content": "blocks"
        }
      }
    }"#,
).unwrap();

let doc = Doc::new();
let txn = doc.transact();
let fragment = txn.get_xml_fragment("root").expect("root");
let segments = render_segments(&txn, &fragment, &rules).expect("Lexical-shaped");
let html = flatten(segments).into_html().expect("no callback rules");
// A stored <callout kind="warning"> renders as
// <aside class="callout callout--warning">…</aside>
```

Attribute templates concatenate literal parts (`lit`) and stored-attribute
references (`ref`); an attribute that resolves empty is omitted. `content`
is `"inline"` (formatted text, the default), `"blocks"` (child block
nodes), or `"none"` (a leaf). `"void": true` skips the closing tag. A rule
for a built-in type replaces how that type renders. There is no marks tier
in this crate: Lexical folds formatting into its text model, which renders
natively. [`prosemirror-yjs-html`](https://crates.io/crates/prosemirror-yjs-html)
has the marks side.

## Callback rules

A rule marked `callback` defers rendering to your code, for nodes that
need logic or a database lookup. Deferred nodes come back as segments
carrying their type, stored attributes as JSON, and already-rendered
children. The render itself never runs your code; you splice the result
after it returns:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use lexical_yjs_html::{escape_attr, escape_text, render_segments, Rules, Segment};

fn splice(segments: Vec<Segment>) -> String {
    segments
        .into_iter()
        .map(|segment| match segment {
            Segment::Html(html) => html,
            Segment::Deferred { node_type, attrs_json, content, .. } => {
                let children = splice(content);
                match node_type.as_str() {
                    "mention" => {
                        let attrs: serde_json::Value =
                            serde_json::from_str(&attrs_json).unwrap();
                        let id = attrs["__id"].as_str().unwrap_or("unknown");
                        // Attribute values are document data, written by
                        // collaborators: escape everything you interpolate.
                        format!(
                            r#"<a class="mention" href="/users/{}">@{}</a>"#,
                            escape_attr(id),
                            escape_text(id)
                        )
                    }
                    _ => children,
                }
            }
        })
        .collect()
}

let rules = Rules::parse(r#"{"nodes": {"mention": {"callback": true}}}"#).unwrap();

let doc = Doc::new();
let txn = doc.transact();
let fragment = txn.get_xml_fragment("root").expect("root");
let segments = render_segments(&txn, &fragment, &rules).expect("Lexical-shaped");
let html = splice(segments);
```

The rules surface (`Rules`, `Segment`, `flatten`) is re-exported here;
[`yjs-html-core`](https://crates.io/crates/yjs-html-core) is an internal
implementation crate.

## Schema discovery

Editors store types and attributes under their own names, and Lexical
prefixes its own props with `__`. `collect_node_types` reports what a real
document holds:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use lexical_yjs_html::{collect_node_types, is_builtin};

let doc = Doc::new();
let txn = doc.transact();
let fragment = txn.get_xml_fragment("root").expect("root");
for (node_type, info) in collect_node_types(&txn, &fragment).unwrap_or_default() {
    println!(
        "{node_type}: {} seen, attrs {:?}, children {:?}, text: {}, built in: {}",
        info.count, info.attrs, info.children, info.text, is_builtin(&node_type),
    );
}
```

Types where `is_builtin` is false need a rule. Without one, the render
degrades instead of erroring, and never drops text: an unknown container
or inline wrapper (a mark-style node) renders its children with no
wrapping markup, and an unknown decorator renders nothing — content that
lives only in the decorator's attributes drops out of the HTML silently.
Render a real document through `collect_node_types` to find the types
that still need rules.

## License

MIT. Developed in [yrby](https://github.com/jpcamara/yrby), where it backs
`Y::Lexical` and `Y::Lexxy`.
