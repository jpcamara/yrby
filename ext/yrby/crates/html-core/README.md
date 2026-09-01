# yjs-html-core

Internal core of
[`lexical-yjs-html`](https://crates.io/crates/lexical-yjs-html) and
[`prosemirror-yjs-html`](https://crates.io/crates/prosemirror-yjs-html):
the per-node render rules and segmented HTML output they share.

Don't depend on this crate directly. The renderer crates re-export its
whole surface (`Rules`, `Segment`, `flatten`, and the rest), and it makes no
stability promise of its own. It's a separate package only because published
crates can't share a path dependency.

Rules come in two tiers. A declarative rule (tag, attributes, text, content
slot) compiles to `NodeRule`/`MarkRule` and renders inside the transaction.
A callback rule defers to the caller: the renderer emits `Segment::Deferred`
with the node's type, attributes as JSON, and its rendered children, and you
splice the result in after the render returns. Your code never runs while
the document is locked. Rules parse from one JSON document (`Rules::parse`),
so the same format works for any binding.

## License

MIT. Developed in [yrby](https://github.com/jpcamara/yrby).
