# yrs-lexical-html

Render a Lexical-shaped [yrs](https://github.com/y-crdt/y-crdt) document to
HTML — no browser, no Node process, no headless editor. Covers core Lexical:
paragraphs, headings, quotes, code blocks, lists, tables, links, and the full
text-format model. Output is pinned byte-for-byte against fixtures captured
from a live editor.

```rust
use yrs::updates::decoder::Decode;
use yrs::{Doc, ReadTxn, Transact, Update};

let doc = Doc::new();
doc.transact_mut()
    .apply_update(Update::decode_v1(&update_bytes)?)?;

let txn = doc.transact();
let fragment = txn.get_xml_fragment("root").expect("Lexical's default root");
let html = yrs_lexical_html::render(&txn, &fragment);
// => Some("<h1>Heading One</h1><p>…</p>") — or None if the fragment
//    isn't Lexical-shaped (e.g. a ProseMirror document).
```

An editor's custom node types render through
[`yrs-render-rules`](../render-rules): pass `Rules` to `render_segments` and
splice any deferred segments yourself. `collect_node_types` reports every
type and attribute a real document stores, so nothing has to be guessed. An
unknown node keeps its content — text and nested blocks degrade to readable
markup rather than disappearing.

## Building and testing

```bash
cargo build -p yrs-lexical-html
cargo test -p yrs-lexical-html
```

Extracted from (and maintained with) [yrby](https://github.com/jpcamara/yrby),
the Rails CRDT sync gem, where it backs `Y::Lexical`/`Y::Lexxy`. Depends only
on yrs, serde_json, and yrs-render-rules. MIT.
