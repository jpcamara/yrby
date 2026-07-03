//! Native HTML rendering of Lexical/Lexxy documents from the yrs collab
//! structure — no Node process, no headless editor.
//!
//! Schema-pinned to Lexxy (37signals' Rails editor, 0.9.x): the output matches
//! what `lexxy-editor`'s own `value` getter produces — i.e. Lexical's
//! `$generateHtmlFromNodes` with Lexxy's custom text export and DOMPurify
//! sanitize applied — byte for byte on the captured fixture. That is the HTML a
//! Lexxy form submits to Rails, so rendering it server-side from the CRDT gives
//! the same canonical document ActionText would store.
//!
//! Prior art: `ueberdosis/tiptap-php` renders ProseMirror JSON to HTML in pure
//! PHP the same way — a schema-pinned renderer outside the JS runtime. This
//! module does that one level deeper, from the collab (Yjs) structure itself.
//!
//! Storage model (verified against bytes captured from a live Lexxy editor):
//! - Blocks are `Y.XmlText` with a `__type` attribute (`paragraph`, `heading`
//!   (+`__tag`), `quote`, `list`/`listitem`, `early_escape_code` (+`__language`),
//!   `wrapped_table_node`/`tablerow`/`tablecell`, `link`/`autolink` (inline)).
//! - Text runs are preceded by an embedded `Y.Map` carrying per-run metadata
//!   (`__type: "text" | "code-highlight" | "tab"`, `__format` bitmask).
//! - `linebreak` is a bare metadata map; `tab` is a map followed by a "\t" run.
//! - Decorator nodes are `Y.XmlElement`s: `horizontal_divider`,
//!   `action_text_attachment` (uploads), `custom_action_text_attachment`
//!   (mentions/embeds), with their fields as plain attributes.
//!
//! Text-format rendering replicates Lexxy's `exportTextNodeDOM` exactly:
//! inner tag `strong` (bold) / `em` (italic, when not bold); outer tag `code` /
//! `mark` / `sub` / `sup`; an `<i>` wrap only when bold+italic combine (the
//! `em` slot is taken); `<s>` / `<u>` wraps always; `<span>`s are unwrapped, so
//! unformatted text is bare. `__style` (colors) and the case-transform format
//! bits are not rendered, matching Lexxy's sanitize output for plain runs.

use yrs::types::text::YChange;
use yrs::{
    Any, GetString, Map, Out, ReadTxn, Text, Xml, XmlElementRef, XmlFragment, XmlFragmentRef,
    XmlOut, XmlTextRef,
};

// Lexical text format bitmask (lexical 0.44).
const FMT_BOLD: u32 = 1;
const FMT_ITALIC: u32 = 1 << 1;
const FMT_STRIKETHROUGH: u32 = 1 << 2;
const FMT_UNDERLINE: u32 = 1 << 3;
const FMT_CODE: u32 = 1 << 4;
const FMT_SUBSCRIPT: u32 = 1 << 5;
const FMT_SUPERSCRIPT: u32 = 1 << 6;
const FMT_HIGHLIGHT: u32 = 1 << 7;

/// Render a Lexical/Lexxy-shaped XML root to HTML, or `None` when the root
/// isn't Lexical-shaped. Lexical marks every node with a `__type` attribute;
/// a root whose children carry none (a ProseMirror document, whose blocks are
/// plain `<paragraph>`-style elements) is a different schema — refuse rather
/// than emit a lossy rendering of it.
///
/// Within a Lexical document, an *individual* unknown node type still renders
/// its text content in a `<p>` rather than disappearing, so a Lexxy upgrade
/// that adds a node degrades to readable output instead of silent loss.
pub fn render<T: ReadTxn>(txn: &T, fragment: &XmlFragmentRef) -> Option<String> {
    if !is_lexical_shaped(txn, fragment) {
        return None;
    }
    let mut out = String::new();
    for node in fragment.children(txn) {
        match node {
            XmlOut::Text(t) => render_block(txn, &t, &mut out),
            XmlOut::Element(e) => render_decorator(txn, &e, &mut out),
            XmlOut::Fragment(f) => out.push_str(&escape_text(&f.get_string(txn))),
        }
    }
    Some(out)
}

/// A root is Lexical-shaped when it is empty or at least one child carries the
/// `__type` attribute Lexical stamps on every node.
fn is_lexical_shaped<T: ReadTxn>(txn: &T, fragment: &XmlFragmentRef) -> bool {
    let mut any_child = false;
    for node in fragment.children(txn) {
        any_child = true;
        let typed = match &node {
            XmlOut::Text(t) => t.get_attribute(txn, "__type").is_some(),
            XmlOut::Element(e) => e.get_attribute(txn, "__type").is_some(),
            XmlOut::Fragment(_) => false,
        };
        if typed {
            return true;
        }
    }
    !any_child // an empty document renders to an empty string
}

/// The `__type` attribute of a block/inline `Y.XmlText`.
fn node_type<T: ReadTxn>(txn: &T, t: &XmlTextRef) -> String {
    match t.get_attribute(txn, "__type") {
        Some(Out::Any(Any::String(s))) => s.to_string(),
        _ => String::new(),
    }
}

/// A string attribute of a block (e.g. `__tag`, `__language`, `__url`).
fn str_attr<T: ReadTxn>(txn: &T, t: &XmlTextRef, name: &str) -> Option<String> {
    match t.get_attribute(txn, name) {
        Some(Out::Any(Any::String(s))) => Some(s.to_string()),
        _ => None,
    }
}

fn render_block<T: ReadTxn>(txn: &T, t: &XmlTextRef, out: &mut String) {
    let ty = node_type(txn, t);
    match ty.as_str() {
        "paragraph" | "provisonal_paragraph" => {
            // (sic: "provisonal" is Lexxy's spelling.) A provisional paragraph
            // is a cursor-placement placeholder; empty ones export to nothing.
            let inline = render_inline(txn, t);
            if inline.is_empty() {
                if ty == "paragraph" {
                    out.push_str("<p><br></p>");
                }
            } else {
                out.push_str("<p>");
                out.push_str(&inline);
                out.push_str("</p>");
            }
        }
        "heading" => {
            let tag = match str_attr(txn, t, "__tag").as_deref() {
                Some(tag @ ("h1" | "h2" | "h3" | "h4" | "h5" | "h6")) => tag.to_string(),
                _ => "h1".to_string(),
            };
            out.push('<');
            out.push_str(&tag);
            out.push('>');
            out.push_str(&render_inline(txn, t));
            out.push_str("</");
            out.push_str(&tag);
            out.push('>');
        }
        "quote" => {
            out.push_str("<blockquote>");
            out.push_str(&render_inline(txn, t));
            out.push_str("</blockquote>");
        }
        "code" | "early_escape_code" => {
            // Lexxy replaces Lexical's CodeNode with its own type; both shapes
            // are accepted. Code highlighting is derived state: token runs
            // flatten to plain text; linebreaks are <br>, tabs a wrapped \t.
            out.push_str("<pre");
            if let Some(lang) = str_attr(txn, t, "__language").filter(|l| !l.is_empty()) {
                out.push_str(" data-language=\"");
                out.push_str(&escape_attr(&lang));
                out.push('"');
            }
            out.push('>');
            out.push_str(&render_inline(txn, t));
            out.push_str("</pre>");
        }
        "list" => {
            let tag = match str_attr(txn, t, "__tag").as_deref() {
                Some("ol") => "ol",
                _ => "ul",
            };
            out.push('<');
            out.push_str(tag);
            out.push('>');
            for child in block_children(txn, t) {
                render_block(txn, &child, out);
            }
            out.push_str("</");
            out.push_str(tag);
            out.push('>');
        }
        "listitem" => render_listitem(txn, t, out),
        "table" | "wrapped_table_node" => {
            out.push_str("<figure class=\"lexxy-content__table-wrapper\"><table><tbody>");
            for row in block_children(txn, t) {
                render_block(txn, &row, out);
            }
            out.push_str("</tbody></table></figure>");
        }
        "tablerow" => {
            out.push_str("<tr>");
            for cell in block_children(txn, t) {
                render_block(txn, &cell, out);
            }
            out.push_str("</tr>");
        }
        "tablecell" => {
            let header = matches!(
                t.get_attribute(txn, "__headerState"),
                Some(Out::Any(Any::Number(n))) if n > 0.0
            ) || matches!(
                t.get_attribute(txn, "__headerState"),
                Some(Out::Any(Any::BigInt(n))) if n > 0
            );
            if header {
                // Class + background match Lexxy's own header-cell export.
                out.push_str(
                    "<th class=\"lexxy-content__table-cell--header\" \
                     style=\"background-color: rgb(242, 243, 245);\">",
                );
            } else {
                out.push_str("<td>");
            }
            for block in block_children(txn, t) {
                render_block(txn, &block, out);
            }
            out.push_str(if header { "</th>" } else { "</td>" });
        }
        // A block type this renderer doesn't know: degrade to a readable
        // paragraph instead of dropping content.
        _ => {
            let inline = render_inline(txn, t);
            if !inline.is_empty() {
                out.push_str("<p>");
                out.push_str(&inline);
                out.push_str("</p>");
            }
        }
    }
}

/// `<li>`: attribute order matches Lexxy's export exactly — checked items put
/// `aria-checked` before `value`; items holding a nested list append the
/// `lexxy-nested-listitem` class after `value`.
fn render_listitem<T: ReadTxn>(txn: &T, t: &XmlTextRef, out: &mut String) {
    let value = match t.get_attribute(txn, "__value") {
        Some(Out::Any(Any::Number(n))) => n as i64,
        Some(Out::Any(Any::BigInt(n))) => n,
        _ => 1,
    };
    let checked = match t.get_attribute(txn, "__checked") {
        Some(Out::Any(Any::Bool(b))) => Some(b),
        _ => None,
    };
    let has_nested_list = block_children(txn, t)
        .into_iter()
        .any(|c| node_type(txn, &c) == "list");

    out.push_str("<li");
    if let Some(c) = checked {
        out.push_str(" aria-checked=\"");
        out.push_str(if c { "true" } else { "false" });
        out.push('"');
    }
    out.push_str(" value=\"");
    out.push_str(&value.to_string());
    out.push('"');
    if has_nested_list {
        out.push_str(" class=\"lexxy-nested-listitem\"");
    }
    out.push('>');
    // Inline content first, then any nested list blocks (Lexical stores the
    // nested list as a child of the item).
    out.push_str(&render_inline(txn, t));
    for child in block_children(txn, t) {
        if node_type(txn, &child) == "list" {
            render_block(txn, &child, out);
        }
    }
    out.push_str("</li>");
}

/// The `Y.XmlText` children of a block that are themselves blocks (list items,
/// nested lists, table rows/cells, cell paragraphs) — inline types excluded.
fn block_children<T: ReadTxn>(txn: &T, t: &XmlTextRef) -> Vec<XmlTextRef> {
    let mut out = Vec::new();
    for d in t.diff(txn, YChange::identity) {
        if let Out::YXmlText(child) = d.insert {
            if !is_inline_type(&node_type(txn, &child)) {
                out.push(child);
            }
        }
    }
    out
}

fn is_inline_type(ty: &str) -> bool {
    matches!(ty, "link" | "autolink")
}

/// Render a block's inline content: formatted text runs, linebreaks, tabs,
/// links, and inline decorators. Nested block children are NOT rendered here
/// (the block renderers handle them), so a list item's text doesn't duplicate
/// its nested list.
fn render_inline<T: ReadTxn>(txn: &T, t: &XmlTextRef) -> String {
    let mut out = String::new();
    // Per-run metadata from the preceding Y.Map embed.
    let mut format: u32 = 0;
    let mut is_tab = false;
    for d in t.diff(txn, YChange::identity) {
        match d.insert {
            Out::YMap(m) => {
                let ty = match m.get(txn, "__type") {
                    Some(Out::Any(Any::String(s))) => s.to_string(),
                    _ => String::new(),
                };
                match ty.as_str() {
                    "linebreak" => out.push_str("<br>"),
                    "tab" => {
                        is_tab = true;
                        format = 0;
                    }
                    // "text", "code-highlight", and anything metadata-shaped:
                    // read the format bits for the run that follows.
                    _ => {
                        is_tab = false;
                        format = match m.get(txn, "__format") {
                            Some(Out::Any(Any::Number(n))) => n as u32,
                            Some(Out::Any(Any::BigInt(n))) => n as u32,
                            _ => 0,
                        };
                    }
                }
            }
            Out::Any(Any::String(s)) => {
                if is_tab {
                    // Lexxy exports a tab as a literal \t in a span.
                    out.push_str("<span>\t</span>");
                    is_tab = false;
                } else {
                    out.push_str(&render_run(&s, format));
                }
            }
            Out::YXmlText(child) => {
                let ty = node_type(txn, &child);
                if is_inline_type(&ty) {
                    render_link(txn, &child, &mut out);
                }
                // Nested blocks are rendered by their parent block's renderer.
            }
            Out::YXmlElement(e) => render_inline_decorator(txn, &e, &mut out),
            _ => {}
        }
    }
    out
}

/// One text run with Lexical's format bitmask, exactly as Lexxy exports it.
fn render_run(text: &str, format: u32) -> String {
    let mut html = escape_text(text);

    // Inner semantic tag (createDOM): strong for bold, em for italic-only.
    // A plain run's span is unwrapped, leaving bare text.
    if format & FMT_BOLD != 0 {
        html = format_wrap(html, "strong");
    } else if format & FMT_ITALIC != 0 {
        html = format_wrap(html, "em");
    }
    // Outer semantic tag (createDOM): first match wins.
    if format & FMT_CODE != 0 {
        html = format_wrap(html, "code");
    } else if format & FMT_HIGHLIGHT != 0 {
        html = format_wrap(html, "mark");
    } else if format & FMT_SUBSCRIPT != 0 {
        html = format_wrap(html, "sub");
    } else if format & FMT_SUPERSCRIPT != 0 {
        html = format_wrap(html, "sup");
    }
    // Lexxy's wrap pass: <i> only when italic couldn't claim the inner tag
    // (bold took it); <b> never fires (bold always claims strong); <s>/<u>
    // always wrap.
    if format & FMT_ITALIC != 0 && format & FMT_BOLD != 0 {
        html = format_wrap(html, "i");
    }
    if format & FMT_STRIKETHROUGH != 0 {
        html = format_wrap(html, "s");
    }
    if format & FMT_UNDERLINE != 0 {
        html = format_wrap(html, "u");
    }
    html
}

fn format_wrap(inner: String, tag: &str) -> String {
    format!("<{tag}>{inner}</{tag}>")
}

/// `link` / `autolink`: Lexxy's sanitize keeps only `href` and `title`
/// (`target`/`rel` are stored in the doc but stripped from exported HTML).
fn render_link<T: ReadTxn>(txn: &T, t: &XmlTextRef, out: &mut String) {
    out.push_str("<a");
    if let Some(url) = str_attr(txn, t, "__url") {
        out.push_str(" href=\"");
        out.push_str(&escape_attr(&url));
        out.push('"');
    }
    if let Some(title) = str_attr(txn, t, "__title").filter(|s| !s.is_empty()) {
        out.push_str(" title=\"");
        out.push_str(&escape_attr(&title));
        out.push('"');
    }
    out.push('>');
    out.push_str(&render_inline(txn, t));
    out.push_str("</a>");
}

/// Root-level decorators: horizontal rule and upload attachments.
fn render_decorator<T: ReadTxn>(txn: &T, e: &XmlElementRef, out: &mut String) {
    match elem_type(txn, e).as_str() {
        "horizontal_divider" => out.push_str("<hr>"),
        "action_text_attachment" => render_upload_attachment(txn, e, out),
        "custom_action_text_attachment" => render_custom_attachment(txn, e, out),
        _ => {} // unknown decorator: nothing extractable
    }
}

/// Inline decorators (inside a paragraph): mention/embed attachments.
fn render_inline_decorator<T: ReadTxn>(txn: &T, e: &XmlElementRef, out: &mut String) {
    match elem_type(txn, e).as_str() {
        "custom_action_text_attachment" => render_custom_attachment(txn, e, out),
        "action_text_attachment" => render_upload_attachment(txn, e, out),
        "horizontal_divider" => out.push_str("<hr>"),
        _ => {}
    }
}

fn elem_type<T: ReadTxn>(txn: &T, e: &XmlElementRef) -> String {
    match e.get_attribute(txn, "__type") {
        Some(Out::Any(Any::String(s))) => s.to_string(),
        _ => String::new(),
    }
}

fn elem_str<T: ReadTxn>(txn: &T, e: &XmlElementRef, name: &str) -> Option<String> {
    match e.get_attribute(txn, name) {
        Some(Out::Any(Any::String(s))) => Some(s.to_string()),
        _ => None,
    }
}

/// A numeric attribute rendered the way JavaScript would print it (integers
/// without a trailing `.0`).
fn elem_num<T: ReadTxn>(txn: &T, e: &XmlElementRef, name: &str) -> Option<String> {
    match e.get_attribute(txn, name) {
        Some(Out::Any(Any::Number(n))) => {
            if n.fract() == 0.0 {
                Some(format!("{}", n as i64))
            } else {
                Some(format!("{n}"))
            }
        }
        Some(Out::Any(Any::BigInt(n))) => Some(format!("{n}")),
        _ => None,
    }
}

fn push_attr(out: &mut String, name: &str, value: &str) {
    out.push(' ');
    out.push_str(name);
    out.push_str("=\"");
    out.push_str(&escape_attr(value));
    out.push('"');
}

/// An upload attachment, in the exact shape ActionText round-trips: attribute
/// order and presence mirror Lexxy's `exportDOM` (nulls omitted, `previewable`
/// only when true, `presentation="gallery"` always).
fn render_upload_attachment<T: ReadTxn>(txn: &T, e: &XmlElementRef, out: &mut String) {
    out.push_str("<action-text-attachment");
    if let Some(v) = elem_str(txn, e, "sgid") {
        push_attr(out, "sgid", &v);
    }
    if matches!(
        e.get_attribute(txn, "previewable"),
        Some(Out::Any(Any::Bool(true)))
    ) {
        push_attr(out, "previewable", "true");
    }
    if let Some(v) = elem_str(txn, e, "src") {
        push_attr(out, "url", &v);
    }
    if let Some(v) = elem_str(txn, e, "altText") {
        push_attr(out, "alt", &v);
    }
    if let Some(v) = elem_str(txn, e, "caption") {
        push_attr(out, "caption", &v);
    }
    if let Some(v) = elem_str(txn, e, "contentType") {
        push_attr(out, "content-type", &v);
    }
    if let Some(v) = elem_str(txn, e, "fileName") {
        push_attr(out, "filename", &v);
    }
    if let Some(v) = elem_num(txn, e, "fileSize") {
        push_attr(out, "filesize", &v);
    }
    if let Some(v) = elem_num(txn, e, "width") {
        push_attr(out, "width", &v);
    }
    if let Some(v) = elem_num(txn, e, "height") {
        push_attr(out, "height", &v);
    }
    push_attr(out, "presentation", "gallery");
    out.push_str("></action-text-attachment>");
}

/// A content attachment (mention, embed): `content` carries the escaped inner
/// HTML; `plainText` is not exported.
fn render_custom_attachment<T: ReadTxn>(txn: &T, e: &XmlElementRef, out: &mut String) {
    out.push_str("<action-text-attachment");
    if let Some(v) = elem_str(txn, e, "sgid") {
        push_attr(out, "sgid", &v);
    }
    if let Some(v) = elem_str(txn, e, "innerHtml") {
        push_attr(out, "content", &v);
    }
    if let Some(v) = elem_str(txn, e, "contentType") {
        push_attr(out, "content-type", &v);
    }
    out.push_str("></action-text-attachment>");
}

/// Text-content escaping, matching what the browser's serializer emits:
/// `&`, `<`, `>` escaped; quotes left alone in text.
fn escape_text(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Attribute-value escaping: text escaping plus `"`.
fn escape_attr(s: &str) -> String {
    escape_text(s).replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::updates::decoder::Decode;
    use yrs::{Doc, Transact, Update};

    /// The whole point: rendering the captured full-schema document must match
    /// Lexxy's own serializer output byte for byte. The fixture pair was
    /// captured together from one live editor session: `lexxy_full.bin` is the
    /// synced Yjs state; `lexxy_full.html` is `lexxy-editor.value` for the same
    /// document (headings h1-h6, every text format bit and the bold+italic
    /// combination, escaping, links with/without title, bullet/numbered/check/
    /// nested lists, quote, highlighted + plain code blocks with tabs, hr,
    /// tables with header cells, mention and upload attachments, tab/linebreak,
    /// and empty paragraphs).
    #[test]
    fn renders_the_captured_lexxy_document_byte_for_byte() {
        let bytes = include_bytes!("fixtures/lexxy_full.bin");
        let expected = include_str!("fixtures/lexxy_full.html");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        assert_eq!(render(&txn, &frag).unwrap(), expected.trim_end());
    }

    #[test]
    fn format_runs_match_lexxys_export_algorithm() {
        // Singles take their semantic tag; the span for plain text unwraps.
        assert_eq!(render_run("x", 0), "x");
        assert_eq!(render_run("x", 1), "<strong>x</strong>");
        assert_eq!(render_run("x", 2), "<em>x</em>");
        assert_eq!(render_run("x", 4), "<s>x</s>");
        assert_eq!(render_run("x", 8), "<u>x</u>");
        assert_eq!(render_run("x", 16), "<code>x</code>");
        assert_eq!(render_run("x", 32), "<sub>x</sub>");
        assert_eq!(render_run("x", 64), "<sup>x</sup>");
        assert_eq!(render_run("x", 128), "<mark>x</mark>");
        // bold+italic: bold claims the inner tag, italic falls back to <i>.
        assert_eq!(render_run("x", 3), "<i><strong>x</strong></i>");
        // Wrap order: u outside s outside the semantic core.
        assert_eq!(render_run("x", 4 | 8), "<u><s>x</s></u>");
        assert_eq!(render_run("x", 1 | 8), "<u><strong>x</strong></u>");
        // Outer tag composes with the inner one.
        assert_eq!(render_run("x", 1 | 16), "<code><strong>x</strong></code>");
        assert_eq!(render_run("x", 2 | 128), "<mark><em>x</em></mark>");
        // Everything at once: u(s(i(outer(inner)))).
        assert_eq!(
            render_run("x", 1 | 2 | 4 | 8 | 16),
            "<u><s><i><code><strong>x</strong></code></i></s></u>"
        );
    }

    #[test]
    fn a_prosemirror_shaped_root_is_refused_not_mangled() {
        // ProseMirror blocks are plain XmlElements with no __type — a
        // different schema. render() must return None, never a lossy or empty
        // rendering that looks like success.
        use yrs::{XmlElementPrelim, XmlFragment, XmlTextPrelim};
        let doc = Doc::new();
        // Create BOTH roots before opening the read transaction:
        // get_or_insert_* opens a write transaction internally and would
        // deadlock against a live read guard (the read_text lesson).
        let frag = doc.get_or_insert_xml_fragment("pm");
        let empty = doc.get_or_insert_xml_fragment("empty");
        {
            let mut txn = doc.transact_mut();
            let p = frag.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            p.push_back(&mut txn, XmlTextPrelim::new("Body"));
        }
        let txn = doc.transact();
        assert_eq!(render(&txn, &frag), None);

        // An empty root is fine: an empty document, not a foreign schema.
        assert_eq!(render(&txn, &empty).as_deref(), Some(""));
    }

    #[test]
    fn escaping_matches_the_browser_serializer() {
        assert_eq!(escape_text(r#"<a & "b">"#), r#"&lt;a &amp; "b"&gt;"#);
        assert_eq!(
            escape_attr(r#"<a & "b">"#),
            r#"&lt;a &amp; &quot;b&quot;&gt;"#
        );
    }
}
