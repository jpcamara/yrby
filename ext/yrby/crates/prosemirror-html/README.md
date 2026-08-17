# prosemirror-yjs-html

Renders the Yjs representation of a [ProseMirror](https://prosemirror.net)
document to HTML, using [yrs](https://crates.io/crates/yrs). Covers
prosemirror-schema-basic plus the prosemirror-tables family, and reads both
naming styles editors use: Tiptap's `bulletList`/`bold` and
prosemirror-schema-basic's `bullet_list`/`strong`. The tests pin the output
byte-for-byte against fixtures captured from a live Tiptap editor.

## Usage

```toml
[dependencies]
prosemirror-yjs-html = "0.1"
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
let fragment = txn.get_xml_fragment("default").expect("Tiptap's default root");
let html = prosemirror_yjs_html::render(&txn, &fragment);
// => Some("<h1>Heading One</h1><p>…</p>") — or None if the fragment
//    isn't ProseMirror-shaped (e.g. a Lexical document).
```

An editor may hold several fragments under one doc; pass whichever root
name your editor binds. `render` returns `None` when the fragment's shape
is not ProseMirror's.

## Declarative rules

A rule describes how a node type the built-in schema does not know should
render: a tag, attribute templates, and a content slot. Declarative rules
render inside the document transaction with no callback:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use prosemirror_yjs_html::{flatten, render_segments, Rules};

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
let fragment = txn.get_xml_fragment("default").expect("default");
let segments = render_segments(&txn, &fragment, &rules).expect("ProseMirror-shaped");
let html = flatten(segments).into_html().expect("no callback rules");
// A stored <callout kind="warning"> renders as
// <aside class="callout callout--warning">…</aside>
```

Attribute templates concatenate literal parts (`lit`) and stored-attribute
references (`ref`); an attribute that resolves empty is omitted. `content`
is `"inline"` (formatted text, the default), `"blocks"` (child block
nodes), or `"none"` (a leaf). `"void": true` skips the closing tag. A rule
for a built-in type replaces how that type renders.

## Mark rules

ProseMirror splits a document into nodes (structure: paragraphs, lists,
tables) and marks (annotations on runs of text: bold, links, comments).
A mark rule registers under `"marks"` and wraps the text runs carrying it:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use prosemirror_yjs_html::{flatten, render_segments, Rules};

let rules = Rules::parse(
    r#"{
      "marks": {
        "comment": {
          "tag": "span",
          "attrs": [["data-comment-id", [{"ref": "id"}]]]
        }
      }
    }"#,
).unwrap();

let doc = Doc::new();
let txn = doc.transact();
let fragment = txn.get_xml_fragment("default").expect("default");
let segments = render_segments(&txn, &fragment, &rules).expect("ProseMirror-shaped");
let html = flatten(segments).into_html().expect("no callback rules");
// A run stored with the comment mark renders as
// <span data-comment-id="c42">…</span>, wrapped outside the built-in marks.
```

Built-in marks nest deterministically: subscript and superscript
innermost, then highlight, underline, strike, italic, bold, a `textStyle`
span, and link on the outside. `code` renders alone among the formatting
marks, matching Tiptap's Code mark. A custom mark wraps outside every
built-in, and several custom marks on one run nest alphabetically by name,
so output never depends on registration order. A rule for a built-in mark
name (`"bold"`) replaces its markup and keeps the exclusivity behavior.

## Callback rules

A rule marked `callback` defers rendering to your code, for nodes that
need logic or a database lookup. Deferred nodes come back as segments
carrying their type, stored attributes as JSON, and already-rendered
children. The render itself never runs your code; you splice the result
after it returns:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use prosemirror_yjs_html::{render_segments, Rules, Segment};

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
                        let id = attrs["id"].as_str().unwrap_or("unknown");
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
let fragment = txn.get_xml_fragment("default").expect("default");
let segments = render_segments(&txn, &fragment, &rules).expect("ProseMirror-shaped");
let html = splice(segments);
```

The rules surface (`Rules`, `Segment`, `flatten`) is re-exported here;
[`yjs-html-core`](https://crates.io/crates/yjs-html-core) is an internal
implementation crate.

## Schema discovery

Editors store types and attributes under their own names; Rhino Editor's
strike mark, for example, is `rhino-strike`. `collect_node_types` reports
what a real document holds:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use prosemirror_yjs_html::{collect_node_types, is_builtin};

let doc = Doc::new();
let txn = doc.transact();
let fragment = txn.get_xml_fragment("default").expect("default");
for (node_type, info) in collect_node_types(&txn, &fragment).unwrap_or_default() {
    println!(
        "{node_type}: {} seen, attrs {:?}, children {:?}, text: {}, built in: {}",
        info.count, info.attrs, info.children, info.text, is_builtin(&node_type),
    );
}
```

Types where `is_builtin` is false need a rule. Without one, an unknown
node still renders its text and nested blocks as plain markup.

## License

MIT. Developed in [yrby](https://github.com/jpcamara/yrby), where it backs
`Y::ProseMirror` and `Y::Tiptap`.
