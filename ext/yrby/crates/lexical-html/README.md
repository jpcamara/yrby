# lexical-yjs-html

Renders a [Lexical](https://lexical.dev) document to HTML straight from its
Yjs form, using [yrs](https://crates.io/crates/yrs). No browser, no Node. It
handles core Lexical: paragraphs, headings, quotes, code blocks, lists,
tables, links, and text formatting. The tests check output byte-for-byte
against documents captured from a real editor.

## Usage

```toml
[dependencies]
lexical-yjs-html = "0.1"
yrs = { version = "0.27", features = ["sync"] }
```

Feed it a Yjs update. That is bytes from your store, a provider, or
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

One doc can hold several fragments. Pass the root name your editor binds.
`render` returns `None` when the fragment isn't Lexical-shaped.

## Declarative rules

For a node type the built-in schema doesn't know, write a rule: a tag,
attribute templates, and a content slot. Declarative rules render in the
transaction, no callback:

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

An attribute template mixes literal parts (`lit`) with stored attributes
(`ref`), and drops out when it resolves empty. `content` is `inline` for
formatted text, `blocks` for child blocks, or `none` for a leaf; `inline`
is the default. `void: true` drops the closing tag. Point a rule at a
built-in type to override it. This crate has no marks tier. Lexical keeps
formatting in the text model, and that renders on its own. For marks, use
[`prosemirror-yjs-html`](https://crates.io/crates/prosemirror-yjs-html).

## Callback rules

Some nodes need real work, like a database lookup. Mark the rule
`callback` and the renderer hands them back to you. Deferred nodes come
back as segments with their type, attributes as JSON, and rendered
children. The render never runs your code. You splice the result in after
it returns:

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

`Rules`, `Segment`, and `flatten` are re-exported here. Depend on this
crate; [`yjs-html-core`](https://crates.io/crates/yjs-html-core) is
internal.

## Schema discovery

Editors name their types and attributes however they like, and Lexical
prefixes its own props with `__`. `collect_node_types` reports what a
document actually holds:

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
