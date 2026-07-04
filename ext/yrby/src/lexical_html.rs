//! Native HTML rendering of Lexical/Lexxy documents from the yrs collab
//! structure — no Node process, no headless editor.
//!
//! Pinned to Lexxy (37signals' Rails editor, 0.9.x). The output matches what
//! `lexxy-editor` produces as its `value`: Lexical's `$generateHtmlFromNodes`,
//! run through Lexxy's text export and DOMPurify. The tests check it byte for
//! byte against a captured fixture. That's the HTML a Lexxy form submits to
//! Rails, so you can store it as ActionText content straight from the CRDT.
//!
//! Prior art: `ueberdosis/tiptap-php` renders ProseMirror JSON to HTML in pure
//! PHP — a schema-pinned renderer outside the JS runtime. This works from the
//! collab (Yjs) structure rather than JSON.
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

// Nesting caps. The block tree is walked on an explicit heap stack (no native
// recursion), so these don't prevent a stack overflow — they just bound how
// deep the renderer descends. Real docs nest a handful of levels deep (the
// torture fixture peaks at ~8); past 1024 a subtree is dropped, but its
// enclosing tags still close. Inline links are still walked recursively (their
// body is inline content, never blocks), so they carry the same cap.
const MAX_BLOCK_DEPTH: usize = 1024;
const MAX_INLINE_DEPTH: usize = 1024;

/// A unit of pending block work on the explicit traversal stack. `Open` renders
/// a block node (pushing its own children as more work); `Close` emits a
/// literal end tag once a container's children have all been processed. Every
/// container's closing tag is a fixed string, so `Close` can borrow `'static`.
enum Work {
    Open(XmlTextRef, usize),
    Close(&'static str),
}

/// Render a Lexical/Lexxy-shaped XML root to HTML, or `None` when the root
/// isn't Lexical-shaped. Lexical marks every node with a `__type` attribute; a
/// root whose children carry none — a ProseMirror document, say, whose blocks
/// are plain `<paragraph>` elements — is a foreign schema, and render returns
/// `None` for it rather than a lossy guess.
///
/// A `__type` the renderer doesn't recognize is handled differently: the node
/// renders its text in a `<p>`, so a Lexxy release that adds one stays readable.
pub fn render<T: ReadTxn>(txn: &T, fragment: &XmlFragmentRef) -> Option<String> {
    if !is_lexical_shaped(txn, fragment) {
        return None;
    }
    let mut out = String::new();
    for node in fragment.children(txn) {
        match node {
            XmlOut::Text(t) => render_block_tree(txn, &t, &mut out),
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

/// Walk a top-level block and everything under it on an explicit heap stack,
/// appending HTML to `out`. Container blocks (lists, tables, cells, list
/// items) push their children back as more work plus a `Close` for their end
/// tag; leaf blocks (paragraphs, headings, quotes, code) render in full on the
/// spot. The stack lives on the heap, so nesting depth can't overflow the
/// native call stack.
fn render_block_tree<T: ReadTxn>(txn: &T, root: &XmlTextRef, out: &mut String) {
    let mut stack: Vec<Work> = vec![Work::Open(root.clone(), 0)];
    while let Some(work) = stack.pop() {
        match work {
            Work::Close(tag) => out.push_str(tag),
            Work::Open(node, depth) => open_block(txn, &node, depth, out, &mut stack),
        }
    }
}

/// Render one block. A container emits its opening tag now and defers its
/// children (and matching `Close`) to the stack; a leaf renders completely.
fn open_block<T: ReadTxn>(
    txn: &T,
    t: &XmlTextRef,
    depth: usize,
    out: &mut String,
    stack: &mut Vec<Work>,
) {
    let ty = node_type(txn, t);
    match ty.as_str() {
        "paragraph" | "provisonal_paragraph" => {
            // (sic: "provisonal" is Lexxy's spelling.) A provisional paragraph
            // is a cursor-placement placeholder; empty ones export to nothing.
            let inline = render_inline(txn, t, 0);
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
            out.push_str(&render_inline(txn, t, 0));
            out.push_str("</");
            out.push_str(&tag);
            out.push('>');
        }
        "quote" => {
            out.push_str("<blockquote>");
            out.push_str(&render_inline(txn, t, 0));
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
            out.push_str(&render_inline(txn, t, 0));
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
            let close = if tag == "ol" { "</ol>" } else { "</ul>" };
            push_block_children(txn, t, depth, close, false, stack);
        }
        "listitem" => open_listitem(txn, t, depth, out, stack),
        "table" | "wrapped_table_node" => {
            out.push_str("<figure class=\"lexxy-content__table-wrapper\"><table><tbody>");
            push_block_children(txn, t, depth, "</tbody></table></figure>", false, stack);
        }
        "tablerow" => {
            out.push_str("<tr>");
            push_block_children(txn, t, depth, "</tr>", false, stack);
        }
        "tablecell" => {
            let header = matches!(
                t.get_attribute(txn, "__headerState"),
                Some(Out::Any(Any::Number(n))) if n > 0.0
            ) || matches!(
                t.get_attribute(txn, "__headerState"),
                Some(Out::Any(Any::BigInt(n))) if n > 0
            );
            let close = if header {
                // Class + background match Lexxy's own header-cell export.
                out.push_str(
                    "<th class=\"lexxy-content__table-cell--header\" \
                     style=\"background-color: rgb(242, 243, 245);\">",
                );
                "</th>"
            } else {
                out.push_str("<td>");
                "</td>"
            };
            push_block_children(txn, t, depth, close, false, stack);
        }
        // A block type this renderer doesn't know: degrade to a readable
        // paragraph instead of dropping content.
        _ => {
            let inline = render_inline(txn, t, 0);
            if !inline.is_empty() {
                out.push_str("<p>");
                out.push_str(&inline);
                out.push_str("</p>");
            }
        }
    }
}

/// Defer a container's block children onto the stack, with its closing tag
/// below them, so the children render in order and the tag closes after. Past
/// `MAX_BLOCK_DEPTH` the children are dropped (the container still closes, so
/// the output stays well formed). `only_lists` keeps just nested-list children,
/// for list items whose inline content the caller has already emitted.
fn push_block_children<T: ReadTxn>(
    txn: &T,
    t: &XmlTextRef,
    depth: usize,
    close: &'static str,
    only_lists: bool,
    stack: &mut Vec<Work>,
) {
    stack.push(Work::Close(close));
    if depth >= MAX_BLOCK_DEPTH {
        return;
    }
    // Reversed: the stack is LIFO, so the last pushed child is rendered first.
    for child in block_children(txn, t).into_iter().rev() {
        if only_lists && node_type(txn, &child) != "list" {
            continue;
        }
        stack.push(Work::Open(child, depth + 1));
    }
}

/// `<li>`: attribute order follows Lexxy's export — checked items put
/// `aria-checked` before `value`; items holding a nested list append the
/// `lexxy-nested-listitem` class after `value`. Inline content renders now;
/// the nested list (if any) is deferred to the stack.
fn open_listitem<T: ReadTxn>(
    txn: &T,
    t: &XmlTextRef,
    depth: usize,
    out: &mut String,
    stack: &mut Vec<Work>,
) {
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
        .iter()
        .any(|c| node_type(txn, c) == "list");

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
    out.push_str(&render_inline(txn, t, 0));
    push_block_children(txn, t, depth, "</li>", true, stack);
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
/// its nested list. `depth` counts inline-link nesting only (a link's body is
/// itself inline content); past `MAX_INLINE_DEPTH` a link renders as flat text,
/// capping the recursion.
fn render_inline<T: ReadTxn>(txn: &T, t: &XmlTextRef, depth: usize) -> String {
    let mut out = String::new();
    // Format carries from the metadata Map that precedes each run. Lexxy always
    // emits one Map immediately before its run, so this is exact; a run with no
    // preceding Map would inherit the previous run's format (wrong, but only
    // reachable from a doc Lexxy didn't produce).
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
                    render_link(txn, &child, depth, &mut out);
                }
                // Nested blocks are rendered by their parent block's renderer.
            }
            Out::YXmlElement(e) => render_inline_decorator(txn, &e, &mut out),
            _ => {}
        }
    }
    out
}

/// One text run with Lexical's format bitmask, as Lexxy's exporter wraps it.
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
fn render_link<T: ReadTxn>(txn: &T, t: &XmlTextRef, depth: usize, out: &mut String) {
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
    if depth < MAX_INLINE_DEPTH {
        out.push_str(&render_inline(txn, t, depth + 1));
    } else {
        // A link chain nested past the cap (only crafted input reaches here):
        // keep its text, drop any further link structure.
        out.push_str(&escape_text(&t.get_string(txn)));
    }
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
/// without a trailing `.0`). Assumes normal-magnitude, finite values — the
/// only numbers here are file sizes and pixel dimensions. A value past i64 or
/// a non-finite one would format differently from `String(n)` (e.g. `1e21`,
/// `Infinity`), but no real attachment carries one.
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

    /// Rendering the captured full-schema document must match Lexxy's own
    /// serializer byte for byte. The pair was captured together from one live
    /// editor session: `lexxy_full.bin` is the synced Yjs state, `lexxy_full.html`
    /// is `lexxy-editor.value` for the same document. It covers every block and
    /// format the schema map handles.
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

    /// A second live-Lexxy pair that stresses nesting: blocks inside table
    /// cells, five-level mixed lists, formatted links in headings, the full
    /// format stack, unicode and escaping edge cases, whitespace-only
    /// paragraphs. The load-bearing structures are probed by name below.
    /// One non-obvious parity fact worth stating: Lexxy's sanitized export
    /// drops colSpan/rowSpan, so matching it byte-for-byte means not emitting
    /// them either.
    #[test]
    fn renders_the_captured_torture_document_byte_for_byte() {
        let bytes = include_bytes!("fixtures/lexxy_torture.bin");
        let expected = include_str!("fixtures/lexxy_torture.html");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let html = render(&txn, &frag).unwrap();
        assert_eq!(html, expected.trim_end());

        // Byte-for-byte already proves these; name the load-bearing ones so
        // a regression fails with the nested structure it broke.
        for (what, probe) in [
            ("list nested in a table cell", "<td><ul><li"),
            ("quote in a table cell", "<td><blockquote>"),
            (
                "code block in a table cell",
                "<td><pre data-language=\"javascript\">cell();</pre></td>",
            ),
            ("mention inside a header cell", "sgid=\"SGID_M_TABLE\""),
            (
                "five-level mixed list nesting",
                "<ol><li value=\"1\"><s><i><strong>Level five</strong></i></s></li></ol>",
            ),
            (
                "the full format stack on one run",
                "<u><s><i><code><strong>g</strong></code></i></s></u>",
            ),
            (
                "a titled link in a heading wrapping formatted runs",
                "<a href=\"https://spec.example.com\" title=\"The Spec\">v<i><strong>2</strong></i><code>.final</code></a>",
            ),
            (
                "already-escaped-looking text escapes again",
                "<strong>a &amp;&amp; b &lt; c &gt; d \"q\" '&amp;amp;'</strong>",
            ),
            ("emoji, CJK and RTL text", "🚀🎉 你好世界 العربية café"),
            (
                "an all-null upload keeps its normalized empty attrs",
                "sgid=\"SGID_UP_MIN\" url=\"http://localhost:4111/files/min.bin\" alt=\"\" caption=\"\"",
            ),
            (
                "whitespace-only paragraphs",
                "<p><span>\t</span></p><p><br></p><p><br></p>",
            ),
        ] {
            assert!(html.contains(probe), "{what}: missing {probe}");
        }
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

    /// Build a chain of `depth` nested lists: list > listitem > list > … each
    /// list holding one item whose only child is the next list down. Mirrors
    /// the real storage model (block children are XmlText embedded in XmlText).
    fn nested_list_doc(depth: usize) -> Doc {
        use yrs::{XmlFragment, XmlTextPrelim};
        let doc = Doc::new();
        let root = doc.get_or_insert_xml_fragment("root");
        let mut txn = doc.transact_mut();
        let top = root.push_back(&mut txn, XmlTextPrelim::new(""));
        top.insert_attribute(&mut txn, "__type", "list");
        top.insert_attribute(&mut txn, "__tag", "ul");
        let mut cursor = top;
        for _ in 0..depth {
            let li = cursor.insert_embed(&mut txn, 0, XmlTextPrelim::new(""));
            li.insert_attribute(&mut txn, "__type", "listitem");
            let inner = li.insert_embed(&mut txn, 0, XmlTextPrelim::new(""));
            inner.insert_attribute(&mut txn, "__type", "list");
            inner.insert_attribute(&mut txn, "__tag", "ul");
            cursor = inner;
        }
        drop(txn);
        doc
    }

    #[test]
    fn deeply_nested_blocks_do_not_overflow_the_stack() {
        // Nesting this deep would overflow the native call stack (tens of
        // thousands of frames) under recursion; on the heap it renders fine.
        // Runs on a 512 KiB thread so it can't pass just by having room to spare.
        let handle = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(|| {
                let doc = nested_list_doc(20_000);
                let txn = doc.transact();
                let frag = txn.get_xml_fragment("root").unwrap();
                let html = render(&txn, &frag).expect("lexical-shaped");
                // Well formed: every opened list/item is closed.
                assert_eq!(html.matches("<ul>").count(), html.matches("</ul>").count());
                assert_eq!(html.matches("<li ").count(), html.matches("</li>").count());
                html.len()
            })
            .unwrap();
        assert!(handle.join().unwrap() > 0);
    }

    #[test]
    fn nesting_past_the_cap_truncates_but_stays_well_formed() {
        // Past MAX_BLOCK_DEPTH the deepest content is dropped, but every
        // enclosing tag still closes, so the output remains balanced HTML.
        let doc = nested_list_doc(MAX_BLOCK_DEPTH + 50);
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let html = render(&txn, &frag).unwrap();

        assert_eq!(html.matches("<ul>").count(), html.matches("</ul>").count());
        assert_eq!(html.matches("<li ").count(), html.matches("</li>").count());
        // Capped, not fully rendered: fewer levels than were authored.
        assert!(html.matches("<ul>").count() <= MAX_BLOCK_DEPTH + 1);
    }

    #[test]
    fn deeply_nested_links_do_not_overflow_the_stack() {
        // Links recurse (their body is inline content), so they carry their own
        // depth cap. A link-in-link chain renders as nested <a>s up to the cap,
        // then bare text.
        use yrs::{XmlFragment, XmlTextPrelim};
        let doc = Doc::new();
        let root = doc.get_or_insert_xml_fragment("root");
        {
            let mut txn = doc.transact_mut();
            let p = root.push_back(&mut txn, XmlTextPrelim::new(""));
            p.insert_attribute(&mut txn, "__type", "paragraph");
            let mut cursor = p;
            for _ in 0..(MAX_INLINE_DEPTH + 20) {
                let link = cursor.insert_embed(&mut txn, 0, XmlTextPrelim::new(""));
                link.insert_attribute(&mut txn, "__type", "link");
                link.insert_attribute(&mut txn, "__url", "https://x.example");
                cursor = link;
            }
        }
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let html = render(&txn, &frag).unwrap();
        assert_eq!(html.matches("<a").count(), html.matches("</a>").count());
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
