# lexical-yjs-html

Renders a [Lexical](https://lexical.dev) document to HTML from its Yjs
representation, using [yrs](https://crates.io/crates/yrs). It covers core
Lexical: paragraphs, headings, quotes, code blocks, lists, tables, links, and
the full text-format model. The tests pin the output byte-for-byte to
fixtures captured from a live editor.

## Usage

```toml
[dependencies]
lexical-yjs-html = "0.1"
yrs = { version = "0.27", features = ["sync"] }
```

The input is a Yjs update: bytes from a durable store, from a provider, or
from `Y.encodeStateAsUpdate` in the browser.

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

One doc can hold several fragments. Pass the root name your editor binds.
`render` returns `None` when the fragment is not Lexical-shaped.

## Declarative rules

A rule tells the renderer how to draw a node type the built-in schema does
not know. A rule is a tag, attribute templates, and a content slot.
Declarative rules render inside the document transaction. Nothing calls
back into your code.

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

An attribute template joins literal parts (`lit`) and stored-attribute
references (`ref`). An attribute that resolves empty is omitted. `content`
is `"inline"` for formatted text, `"blocks"` for child block nodes, or
`"none"` for a leaf. `"inline"` is the default. `"void": true` skips the
closing tag. A rule for a built-in type replaces how that type renders.
This crate has no marks tier. Lexical keeps formatting inside its text
model, and the renderer handles that natively.
[`prosemirror-yjs-html`](https://crates.io/crates/prosemirror-yjs-html) has
the marks side.

## Callback rules

A rule marked `callback` hands the node to your code. Use it for nodes that
need logic or a database lookup. Deferred nodes come back as segments with
their type, their stored attributes as JSON, and their children already
rendered. The render never runs your code. You splice the result in after
it returns.

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use lexical_yjs_html::{render_segments, Rules, Segment};

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
                        // Look the user up, build trusted markup, escape
                        // anything you interpolate.
                        format!(r#"<a class="mention" href="/users/{id}">@{id}</a>"#)
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

`Rules`, `Segment`, and `flatten` are re-exported here.
[`yjs-html-core`](https://crates.io/crates/yjs-html-core) is an internal
implementation crate.

## Schema discovery

Editors store types and attributes under their own names. Lexical prefixes
its own props with `__`. `collect_node_types` reports what a real document
holds:

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

Anything where `is_builtin` is false needs a rule. Without one, the node
still renders its text and child blocks, just unwrapped.

## License

MIT. Developed in [yrby](https://github.com/jpcamara/yrby), where it backs
`Y::Lexical` and `Y::Lexxy`.
