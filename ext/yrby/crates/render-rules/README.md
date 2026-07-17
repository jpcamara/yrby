# yrs-render-rules

**Internal support crate** for
[`yrs-lexical-html`](../lexical-html) and
[`yrs-prosemirror-html`](../prosemirror-html): the per-node render rules and
segmented HTML output they share.

Don't depend on this crate directly — the renderers re-export its entire
surface (`Rules`, `Segment`, `flatten`, ...), and this crate makes no API
stability promises of its own. It exists as a separate package only because
published crates can't share a path dependency.

Rules come in two tiers. Declarative rules (tag, attributes, text, content
slot) compile to `NodeRule`/`MarkRule` and render natively, inside the
document transaction. Callback rules defer to the caller: the renderer emits
`Segment::Deferred` entries carrying the node's type, attributes (as JSON),
and its already-rendered children, and the caller splices the result in after
the render returns — application code never runs while the document is
locked. Rules arrive as one JSON document (`Rules::parse`), so the same
format serves any binding.

## Building and testing

```bash
cargo build -p yrs-render-rules
cargo test -p yrs-render-rules
```

Extracted from (and maintained with) [yrby](https://github.com/jpcamara/yrby),
the Rails CRDT sync gem. MIT.
