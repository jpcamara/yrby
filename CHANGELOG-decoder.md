# Changelog — y-ruby-decoder

All notable changes to the `y-ruby-decoder` gem.

## [Unreleased]

### Added
- Initial scaffold. `Y::Decoder` reconstructs plain text from a stored Yjs
  CRDT state **in pure Ruby**, in-process, on the core gem's native extension —
  no Node, no subprocess, no binary:
  - `text` — plain text (Lexical `Y.XmlText`, plain `Y.Text`, ProseMirror
    `Y.XmlFragment`), for search indexing and exports.
  - `preview` — a compact, truncated single-line preview for list UIs.
- Block boundaries are preserved as newlines across all three editors, so
  adjacent paragraphs don't merge into one run of words (which would break word
  boundaries for search). Verified against real Lexical, ProseMirror/TipTap, and
  plain-text fixtures in `test/decoder_test.rb`.
- Requires the core `Doc` content readers (`root_names`, `read_text`, `read_xml`,
  `read_map`); `read_xml` joins a root's top-level blocks with newlines, and
  `read_map` serializes a `Y.Map` root to a JSON object string (sorted keys,
  recursive values) — for reading structured shared state server-side.

Full-fidelity Lexical reconstruction (EditorState JSON / HTML) is intentionally
**not** in this gem; it's the separate, opt-in `y-ruby-decode` Bun binary (see
`packages/y-ruby-decode`).
