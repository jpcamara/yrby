//! Pure content-reading helpers over yrs shared types — no magnus/Ruby, so they
//! can be unit-tested directly in Rust (like `protocol.rs`). The binding layer in
//! `lib.rs` is a thin wrapper that opens a transaction and calls these.

use std::collections::HashMap;
use std::sync::Arc;
use yrs::types::text::YChange;
use yrs::{
    Any, Array, GetString, Map, MapRef, Out, ReadTxn, Text, Xml, XmlFragment, XmlFragmentRef,
    XmlOut, XmlTextRef,
};

/// Read an XML-shaped root as text, one top-level block per line.
///
/// Two editors store their documents differently, and both are handled:
///
/// - **ProseMirror** (Tiptap) stores blocks as `Y.XmlElement` children
///   (`<paragraph>…`). `get_string` already recurses these (tags included; the
///   caller strips them), so we keep that path.
/// - **Lexical** (Lexxy) stores every node as a `Y.XmlText`, and nests child
///   blocks (list items, table cells, nested lists) as *embedded* `Y.XmlText`s —
///   which `get_string` silently omits, dropping all that content. So for a
///   Lexical block we walk its content (`Text::diff`) instead: text runs build a
///   line, inline children (links) join it, and nested block children flush the
///   line and recurse. Each leaf block becomes one line, so words never glue
///   across blocks and lists/tables come through intact.
pub fn xml_blocks_text<T: ReadTxn>(txn: &T, fragment: &XmlFragmentRef) -> String {
    let mut out: Vec<String> = Vec::new();
    for node in fragment.children(txn) {
        match node {
            XmlOut::Text(t) => walk_lexical_block(txn, &t, &mut out),
            XmlOut::Element(e) => {
                // ProseMirror blocks have a tag but no `__type`; get_string recurses
                // them (tags kept, caller strips). A Lexical decorator is an
                // XmlElement *with* a `__type`: attachments carry readable text
                // (a mention's plain text, an upload's caption); the rest
                // (horizontal rule) have none — skip rather than emit their
                // `<UNDEFINED …>` serialization.
                if e.get_attribute(txn, "__type").is_none() {
                    out.push(e.get_string(txn));
                } else if let Some(text) = lexical_decorator_text(txn, &e) {
                    out.push(text);
                }
            }
            XmlOut::Fragment(f) => out.push(f.get_string(txn)),
        }
    }
    out.join("\n")
}

/// Lexical node `__type`s whose text belongs on the surrounding line rather than
/// a new block (e.g. a link inside a paragraph). Everything else with embedded
/// child `Y.XmlText`s is treated as a block and recursed.
fn is_inline_lexical_type(ty: &str) -> bool {
    matches!(
        ty,
        "text" | "link" | "autolink" | "linebreak" | "tab" | "hashtag" | "mark" | "overflow"
    )
}

/// A Lexical node's `__type` (stored as an XML attribute on its `Y.XmlText`).
fn lexical_type<T: ReadTxn>(txn: &T, t: &XmlTextRef) -> String {
    match t.get_attribute(txn, "__type") {
        Some(Out::Any(Any::String(s))) => s.to_string(),
        _ => String::new(),
    }
}

/// The readable text of a Lexical decorator element, if it has any: a mention
/// or embed attachment contributes its plain text; an upload attachment its
/// caption, alt text, or filename. Dividers and unknown decorators yield None.
fn lexical_decorator_text<T: ReadTxn>(txn: &T, e: &yrs::XmlElementRef) -> Option<String> {
    let attr = |name: &str| match e.get_attribute(txn, name) {
        Some(Out::Any(Any::String(s))) if !s.is_empty() => Some(s.to_string()),
        _ => None,
    };
    match e.get_attribute(txn, "__type") {
        Some(Out::Any(Any::String(ty))) => match ty.as_ref() {
            "custom_action_text_attachment" => attr("plainText"),
            "action_text_attachment" => attr("caption")
                .or_else(|| attr("altText"))
                .or_else(|| attr("fileName")),
            _ => None,
        },
        _ => None,
    }
}

/// The `__type` of an embedded Lexical `Y.Map`. Two kinds appear inside a
/// block: text-node metadata (`"text"`) and node maps like the LineBreakNode
/// (`"linebreak"`). Structure confirmed from live-editor bytes (see the
/// captured-fixture test).
fn lexical_map_type<T: ReadTxn>(txn: &T, m: &MapRef) -> String {
    match m.get(txn, "__type") {
        Some(Out::Any(Any::String(s))) => s.to_string(),
        _ => String::new(),
    }
}

/// Gather the text of an inline Lexical element (its text runs and any nested
/// inline elements) without introducing block breaks.
fn inline_lexical_text<T: ReadTxn>(txn: &T, t: &XmlTextRef, buf: &mut String) {
    for d in t.diff(txn, YChange::identity) {
        match d.insert {
            Out::Any(Any::String(s)) => buf.push_str(&s),
            Out::YXmlText(child) => inline_lexical_text(txn, &child, buf),
            Out::YMap(m) => match lexical_map_type(txn, &m).as_str() {
                "linebreak" => buf.push('\n'),
                "tab" => buf.push('\t'),
                _ => {} // per-text-node metadata: no text of its own
            },
            _ => {} // decorator embeds: no text
        }
    }
}

/// Walk a Lexical block (`Y.XmlText`), pushing one line per leaf block. Text runs
/// accumulate; inline children join the line; block children flush it and recurse.
fn walk_lexical_block<T: ReadTxn>(txn: &T, t: &XmlTextRef, out: &mut Vec<String>) {
    let mut line = String::new();
    for d in t.diff(txn, YChange::identity) {
        match d.insert {
            Out::Any(Any::String(s)) => line.push_str(&s),
            // Node maps: linebreak/tab carry no text, so emit the character
            // they represent ("foo⏎bar" must not become "foobar"). Metadata
            // maps ("text") stay silent.
            Out::YMap(m) => match lexical_map_type(txn, &m).as_str() {
                "linebreak" => line.push('\n'),
                "tab" => line.push('\t'),
                _ => {}
            },
            Out::YXmlText(child) => {
                let ty = lexical_type(txn, &child);
                match ty.as_str() {
                    // Defensive only: real Lexical stores these as Y.Map embeds.
                    "linebreak" => line.push('\n'),
                    "tab" => line.push('\t'),
                    _ if is_inline_lexical_type(&ty) => inline_lexical_text(txn, &child, &mut line),
                    _ => {
                        if !line.is_empty() {
                            out.push(std::mem::take(&mut line));
                        }
                        walk_lexical_block(txn, &child, out);
                    }
                }
            }
            // An inline decorator (a mention attachment) joins the line.
            Out::YXmlElement(e) => {
                if let Some(text) = lexical_decorator_text(txn, &e) {
                    line.push_str(&text);
                }
            }
            _ => {} // other embeds carry no text
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
}

/// Read a `Y.Map` root as a JSON object string (keys sorted for stable output).
///
/// The complement to `read_text`/`read_xml` for structured state — e.g. a shared
/// "view state" map. Values are converted recursively: primitives pass through;
/// nested `Y.Map`/`Y.Array` recurse; `Y.Text`/XML values stringify. The caller
/// parses the JSON (yrs's own `Out::to_json` is crate-private, so we walk the
/// `Out` variants ourselves here).
pub fn map_json<T: ReadTxn>(txn: &T, map: &MapRef) -> String {
    let mut pairs: Vec<(String, Any)> = map
        .iter(txn)
        .map(|(k, v)| (k.to_string(), out_to_any(txn, &v)))
        .collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0)); // deterministic key order
    let mut out = String::from("{");
    for (i, (k, v)) in pairs.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        // Any::to_json serializes from the start of the buffer (it doesn't
        // append), so each piece goes into its own String, then concatenated.
        out.push_str(&any_to_json(&Any::String(Arc::from(k.as_str())))); // JSON-escaped key
        out.push(':');
        out.push_str(&any_to_json(v));
    }
    out.push('}');
    out
}

fn any_to_json(a: &Any) -> String {
    let mut s = String::new();
    a.to_json(&mut s);
    s
}

/// Convert a yrs output value to an `Any` (which knows how to JSON-serialize),
/// recursing through nested shared collections.
fn out_to_any<T: ReadTxn>(txn: &T, out: &Out) -> Any {
    match out {
        Out::Any(a) => a.clone(),
        Out::YText(v) => Any::from(v.get_string(txn)),
        Out::YXmlText(v) => Any::from(v.get_string(txn)),
        Out::YXmlElement(v) => Any::from(v.get_string(txn)),
        Out::YXmlFragment(v) => Any::from(v.get_string(txn)),
        Out::YArray(arr) => {
            let items: Vec<Any> = arr.iter(txn).map(|o| out_to_any(txn, &o)).collect();
            Any::Array(items.into())
        }
        Out::YMap(m) => {
            let mut hm: HashMap<String, Any> = HashMap::new();
            for (k, v) in m.iter(txn) {
                hm.insert(k.to_string(), out_to_any(txn, &v));
            }
            Any::Map(Arc::new(hm))
        }
        _ => Any::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::{Doc, MapPrelim, Transact, XmlElementPrelim, XmlTextPrelim};

    #[test]
    fn prosemirror_blocks_keep_tags_and_separate_with_newlines() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("pm");
        {
            let mut txn = doc.transact_mut();
            let h = frag.push_back(&mut txn, XmlElementPrelim::empty("heading"));
            h.push_back(&mut txn, XmlTextPrelim::new("Title"));
            let p = frag.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            p.push_back(&mut txn, XmlTextPrelim::new("Body"));
        }
        let txn = doc.transact();
        assert_eq!(
            xml_blocks_text(&txn, &frag),
            "<heading>Title</heading>\n<paragraph>Body</paragraph>"
        );
    }

    #[test]
    fn lexical_style_sibling_text_blocks_separate_with_newlines() {
        // Lexical stores each block as a sibling XmlText with no element tags;
        // this is the case a flat read glued together.
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("lex");
        {
            let mut txn = doc.transact_mut();
            frag.push_back(&mut txn, XmlTextPrelim::new("first paragraph"));
            frag.push_back(&mut txn, XmlTextPrelim::new("second paragraph"));
        }
        let txn = doc.transact();
        assert_eq!(
            xml_blocks_text(&txn, &frag),
            "first paragraph\nsecond paragraph"
        );
    }

    #[test]
    fn single_block_has_no_trailing_separator() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("one");
        {
            let mut txn = doc.transact_mut();
            frag.push_back(&mut txn, XmlTextPrelim::new("only"));
        }
        let txn = doc.transact();
        assert_eq!(xml_blocks_text(&txn, &frag), "only");
    }

    #[test]
    fn empty_fragment_is_blank() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("empty");
        let txn = doc.transact();
        assert_eq!(xml_blocks_text(&txn, &frag), "");
    }

    #[test]
    fn map_json_serializes_primitives_with_sorted_keys() {
        let doc = Doc::new();
        let map = doc.get_or_insert_map("state");
        {
            let mut txn = doc.transact_mut();
            map.insert(&mut txn, "title", "Dashboard");
            map.insert(&mut txn, "count", 3_i64);
            map.insert(&mut txn, "active", true);
        }
        let txn = doc.transact();
        assert_eq!(
            map_json(&txn, &map),
            r#"{"active":true,"count":3,"title":"Dashboard"}"#
        );
    }

    #[test]
    fn map_json_recurses_into_nested_map() {
        let doc = Doc::new();
        let map = doc.get_or_insert_map("state");
        {
            let mut txn = doc.transact_mut();
            let inner = map.insert(&mut txn, "user", MapPrelim::default());
            inner.insert(&mut txn, "name", "Ada");
        }
        let txn = doc.transact();
        assert_eq!(map_json(&txn, &map), r#"{"user":{"name":"Ada"}}"#);
    }

    #[test]
    fn map_json_empty_is_object() {
        let doc = Doc::new();
        let map = doc.get_or_insert_map("state");
        let txn = doc.transact();
        assert_eq!(map_json(&txn, &map), "{}");
    }

    #[test]
    fn lexical_soft_line_break_and_tab_emit_their_characters() {
        // A paragraph "foo⏎bar" (shift-enter): Lexical stores the LineBreakNode
        // as an embedded Y.Map with __type=linebreak (the same shape as the
        // per-text-node metadata maps, which must stay silent). It must come
        // through as '\n', not vanish and glue the words. Same for tab.
        use yrs::{Text, XmlTextPrelim};
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("lex");
        {
            let mut txn = doc.transact_mut();
            let block = frag.push_back(&mut txn, XmlTextPrelim::new(""));
            let meta: MapPrelim = [("__type", yrs::In::from("text"))].into_iter().collect();
            block.insert_embed(&mut txn, 0, meta); // metadata map: no text
            block.push(&mut txn, "foo");
            let br: MapPrelim = [("__type", yrs::In::from("linebreak"))]
                .into_iter()
                .collect();
            block.insert_embed(&mut txn, 4, br);
            block.push(&mut txn, "bar");
            let tab: MapPrelim = [("__type", yrs::In::from("tab"))].into_iter().collect();
            block.insert_embed(&mut txn, 8, tab);
            block.push(&mut txn, "baz");
        }
        let txn = doc.transact();
        assert_eq!(xml_blocks_text(&txn, &frag), "foo\nbar\tbaz");
    }

    #[test]
    fn lexical_real_captured_linebreak_extracts_as_newline() {
        // Ground truth: bytes captured from a LIVE Lexxy editor (agent-browser
        // typing "foo", pressing Shift+Enter, typing "barbaz"), served by the
        // yrby test server's durable store. The hand-built test above models
        // this structure; this one IS the structure. Regenerate by driving
        // lexxy-realtime's test server and saving GET /content/:room.
        use yrs::updates::decoder::Decode;
        use yrs::Update;
        let bytes = include_bytes!("fixtures/lexical_linebreak.bin");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        assert_eq!(xml_blocks_text(&txn, &frag), "foo\nbarbaz");
    }

    #[test]
    fn lexxy_full_schema_doc_extracts_attachment_text_too() {
        // The full-schema capture (see lexical_html.rs): attachments must now
        // contribute readable text — a mention's plain text inline, an
        // upload's caption as its own line — while the divider stays silent.
        use yrs::updates::decoder::Decode;
        use yrs::{Transact, Update};
        let bytes = include_bytes!("fixtures/lexxy_full.bin");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let text = xml_blocks_text(&txn, &frag);

        assert!(
            text.contains("Mention: @Alice done."),
            "inline mention joins its line:\n{text}"
        );
        assert!(
            text.contains("The team, 2026"),
            "upload caption becomes a line"
        );
        assert!(
            !text.contains("UNDEFINED"),
            "no decorator serialization leaks"
        );
        assert!(
            !text.contains('\u{2504}'),
            "the divider glyph is not emitted"
        );
        for expected in ["Heading H6", "Done item", "def hello", "after-empty"] {
            assert!(text.contains(expected), "missing {expected:?}");
        }
    }

    #[test]
    fn lexical_complex_doc_extracts_all_nested_text() {
        // A real Lexxy/Lexical doc with every block type: headings, formatted
        // text, an inline link, bullet + NESTED bullet + numbered + check lists,
        // a quote, a code block, a horizontal rule, and a table. Every piece of
        // text -- including list items, the nested sub-list, and table cells --
        // must come through (get_string alone dropped all the nested ones).
        use yrs::updates::decoder::Decode;
        use yrs::{Transact, Update};
        let bytes = include_bytes!("fixtures/lexical_rich.bin");
        let doc = Doc::new();
        {
            let mut txn = doc.transact_mut();
            txn.apply_update(Update::decode_v1(bytes).unwrap()).unwrap();
        }
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let text = xml_blocks_text(&txn, &frag);
        for expected in [
            "Heading One",
            "Heading Two",
            "Plain, bold, italic, strike, underline, and code.",
            "Visit the website for more.", // link text stays inline
            "First bullet",
            "Second bullet",
            "Nested A", // nested sub-list
            "Nested B",
            "Step one",
            "Step two",
            "Done item",
            "Todo item",
            "A blockquote about CRDTs.",
            "const x = 1;", // code block (keeps its internal newline)
            "console.log(x);",
            "Name", // table header cells
            "Role",
            "Ada", // table body cells
            "Engineer",
        ] {
            assert!(text.contains(expected), "missing {expected:?} in:\n{text}");
        }
        // The inline link must NOT have been split onto its own line.
        assert!(text.contains("Visit the website for more."));
    }
}
