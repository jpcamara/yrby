# yjs-html-core

Internal core of
[`lexical-yjs-html`](https://crates.io/crates/lexical-yjs-html) and
[`prosemirror-yjs-html`](https://crates.io/crates/prosemirror-yjs-html):
the per-node render rules and segmented HTML output they share.

Do not depend on this crate directly. The renderer crates re-export its
entire surface (`Rules`, `Segment`, `flatten`, and the rest). This crate
makes no API stability promises of its own. It is a separate package only
because published crates cannot share a path dependency.

Rules come in two tiers. A declarative rule is a tag, attributes, text, and
a content slot. It compiles to a `NodeRule` or `MarkRule` and renders inside
the document transaction. A callback rule defers to the caller. The renderer
emits `Segment::Deferred` entries with the node's type, its attributes as
JSON, and its already-rendered children, and the caller splices the result
in after the render returns. Application code never runs while the document
is locked. Rules parse from one JSON document (`Rules::parse`), so the same
format serves any binding.

## License

MIT. Developed in [yrby](https://github.com/jpcamara/yrby).
