# yrs-prosemirror-html

Render a ProseMirror-shaped [yrs](https://github.com/y-crdt/y-crdt) document
to HTML — no browser, no Node process, no headless editor. Covers
prosemirror-schema-basic plus the prosemirror-tables family, and reads both
naming styles editors use (Tiptap's `bulletList`/`bold` and
prosemirror-schema-basic's `bullet_list`/`strong`). Output is pinned
byte-for-byte against fixtures captured from a live Tiptap editor.

Every example below is compile-checked by `cargo test`.

## Rendering a document

The bytes are a Yjs update — from your durable store, a provider, or
`Y.encodeStateAsUpdate` in the browser:

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
let html = yrs_prosemirror_html::render(&txn, &fragment);
// => Some("<h1>Heading One</h1><p>…</p>") — or None if the fragment
//    isn't ProseMirror-shaped (e.g. a Lexical document).
```

An editor may hold several fragments under one doc; pass whichever root name
your editor binds. `render` returns `None` rather than guessing when the
fragment's shape isn't ProseMirror's.

## Custom nodes, declaratively

Editors add node and mark types the base schema never heard of. A
declarative rule is
markup as data — tag, attributes, content slot — and renders natively:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use yrs_prosemirror_html::{flatten, render_segments, Rules};

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
nodes), or `"none"` (a leaf); `"void": true` skips the closing tag. A rule
for a built-in type replaces how that type renders.

## Custom marks

ProseMirror splits a document into nodes (the structure: paragraphs, lists,
tables) and marks (annotations on runs of text: bold, links, comments). The
split is ProseMirror's — the Lexical crate has no marks tier, because
Lexical folds formatting into its core text model and renders it natively.

A mark rule registers under `"marks"` and wraps the text runs carrying it:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use yrs_prosemirror_html::{flatten, render_segments, Rules};

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

The built-in marks nest deterministically (subscript/superscript innermost,
then highlight, underline, strike, italic, bold, a `textStyle` span, link on
the outside), and `code` renders alone among the formatting marks, matching
Tiptap's Code mark. A custom mark wraps outside every built-in; several on
one run nest alphabetically by name, so output never depends on
registration order. A rule for a built-in mark name (`"bold"`) replaces its
markup while the exclusivity behavior holds.

## Custom nodes, with your own code

When markup-as-data isn't enough — the node needs a database lookup, or
logic — mark the rule `callback` and the renderer defers it to you. The
render itself never runs your code: deferred nodes come back as segments
carrying their type, stored attributes (as JSON), and already-rendered
children, and you splice the result:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use yrs_prosemirror_html::{render_segments, Rules, Segment};

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

(The rules surface — `Rules`, `Segment`, `flatten`, and friends — is
re-exported here; `yrs-html-core` is an internal implementation crate.)

## Discovering what a document stores

Editors store types and attributes under names you'd never predict (Rhino
Editor's strike mark is `rhino-strike`). Don't guess — ask a real document:

```rust,no_run
use yrs::{Doc, Transact, ReadTxn};
use yrs_prosemirror_html::{collect_node_types, is_builtin};

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

Types where `is_builtin` is false are the ones needing a rule — and even
without one, an unknown node keeps its content: text and nested blocks
degrade to readable markup rather than disappearing.

## Building and testing

```bash
cargo build -p yrs-prosemirror-html
cargo test -p yrs-prosemirror-html
```

Extracted from (and maintained with) [yrby](https://github.com/jpcamara/yrby),
the Rails CRDT sync gem, where it backs `Y::ProseMirror`/`Y::Tiptap`. Depends only
on yrs, serde_json, and yrs-html-core. MIT.
