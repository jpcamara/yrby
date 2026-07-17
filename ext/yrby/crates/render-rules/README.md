# yrs-render-rules

The extensibility core shared by [`yrs-lexical-html`](../lexical-html) and
[`yrs-prosemirror-html`](../prosemirror-html): per-node render rules and
segmented HTML output for [yrs](https://github.com/y-crdt/y-crdt) XML trees.

Rules come in two tiers. Declarative rules (tag, attributes, text, content
slot) compile to `NodeRule`/`MarkRule` and render natively, inside the
document transaction. Callback rules defer to the caller: the renderer emits
`Segment::Deferred` entries carrying the node's type, attributes (as JSON),
and its already-rendered children, and the caller splices the result in after
the render returns — application code never runs while the document is
locked. Rules arrive as one JSON document (`Rules::parse`), so the same
format serves any binding or caller.

You usually want one of the renderer crates rather than this directly; this
crate is for building a renderer for another editor's document shape.

## Building and testing

```bash
cargo build -p yrs-render-rules
cargo test -p yrs-render-rules
```

Extracted from (and maintained with) [yrby](https://github.com/jpcamara/yrby),
the Rails CRDT sync gem, but depends only on yrs and serde_json. MIT.
