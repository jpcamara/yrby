# yjs-html-core

Internal core of
[`lexical-yjs-html`](https://crates.io/crates/lexical-yjs-html) and
[`prosemirror-yjs-html`](https://crates.io/crates/prosemirror-yjs-html):
the per-node render rules and segmented HTML output they share.

Do not depend on this crate directly. The renderer crates re-export its
entire surface (`Rules`, `Segment`, `flatten`, and the rest), and this crate
makes no API stability promises of its own. It is a separate package only
because published crates cannot share a path dependency.

Rules come in two tiers. Declarative rules (tag, attributes, text, content
slot) compile to `NodeRule`/`MarkRule` and render inside the document
transaction. Callback rules defer to the caller: the renderer emits
`Segment::Deferred` entries carrying the node's type, attributes as JSON,
and its already-rendered children, and the caller splices the result in
after the render returns. Application code never runs while the document is
locked. Rules parse from one JSON document (`Rules::parse`), so the same
format serves any binding.

## License

MIT. Developed in [yrby](https://github.com/jpcamara/yrby).
