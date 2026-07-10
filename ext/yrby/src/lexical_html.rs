//! Native HTML rendering of Lexical documents from the yrs collab structure —
//! no Node process, no headless editor.
//!
//! This renders **core Lexical**: paragraphs, headings, quotes, code, lists
//! and list items, tables, horizontal rules, links, and the whole text-format
//! model. Everything Lexxy-specific — its own node types (attachments,
//! galleries, `early_escape_code`, `horizontal_divider`) and its decorations
//! of core nodes (the table figure wrapper, header-cell styling, the
//! nested-list-item class) — lives in the Ruby layer as render rules
//! (`Y::Lexxy::NODES`), built on the same extension API apps use. The Lexxy
//! byte-parity guarantee is held there: the Ruby fixture tests and the live
//! headless-Chrome e2e pin `Y::Lexical#to_html` against a real editor's own
//! serialized value. The native tests pin core output as regression goldens
//! (stock Lexical has no canonical serializer to capture against).
//!
//! Prior art: `ueberdosis/tiptap-php` renders ProseMirror JSON to HTML in pure
//! PHP — a schema-pinned renderer outside the JS runtime. This works from the
//! collab (Yjs) structure rather than JSON.
//!
//! Storage model (verified against bytes captured from a live editor):
//! - Blocks are `Y.XmlText` with a `__type` attribute (`paragraph`, `heading`
//!   (+`__tag`), `quote`, `code` (+`__language`), `list`/`listitem`,
//!   `table`/`tablerow`/`tablecell`, `link`/`autolink` (inline)).
//! - Text runs are preceded by an embedded `Y.Map` carrying per-run metadata
//!   (`__type: "text" | "code-highlight" | "tab"`, `__format` bitmask).
//! - `linebreak` is a bare metadata map; `tab` is a map followed by a "\t" run.
//! - Decorator nodes are `Y.XmlElement`s with their fields as plain
//!   attributes (`horizontalrule` here; app/Lexxy decorators via rules).
//!
//! Text-format rendering follows the export pipeline Lexxy runs (Lexical's
//! `$generateHtmlFromNodes` + sanitize), which is the only externally
//! pinnable truth for formatting: inner tag `strong` (bold) / `em` (italic,
//! when not bold); outer tag `code` / `mark` / `sub` / `sup`; an `<i>` wrap
//! only when bold+italic combine (the `em` slot is taken); `<s>` / `<u>`
//! wraps always; `<span>`s are unwrapped, so unformatted text is bare. A
//! run's `__style` (highlight colors) survives on the createDOM tag,
//! filtered to color/background-color; on a plain or s/u-only run it dies
//! with the unwrapped span. Case-transform format bits are never rendered
//! (their text-transform style is outside the sanitize whitelist).
//!
//! Custom nodes: rules are registered by `__type` (see `render_rules`) and
//! consulted before the built-in arms, so they extend the schema or override
//! a built-in. Declarative rules render here; callback rules emit
//! `Segment::Deferred` for the Ruby layer to fill in after the render.

use crate::render_rules::{
    resolve_parts, xml_attrs_json, xml_ref_attr, Content, Emitter, NodeRule, Rules, Segment,
};
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

/// A unit of block work on the explicit traversal stack. `Open`
/// renders a block node (pushing its own children as more work); `Close` and
/// `CloseOwned` emit an end tag once a container's children have all been
/// processed (built-in containers close with fixed strings; rule containers
/// close with their computed tag). `EndDeferred` seals a callback node: it pops
/// the emitter frame its children rendered into and emits the deferred segment.
enum Work {
    Open(XmlTextRef, usize),
    Close(&'static str),
    CloseOwned(String),
    EndDeferred {
        node_type: String,
        attrs_json: String,
        child_types: Vec<String>,
    },
}

/// Render a Lexical/Lexxy-shaped XML root, or `None` when the root isn't
/// Lexical-shaped. Lexical marks every node with a `__type` attribute; a
/// root whose children carry none — a ProseMirror document, say, whose blocks
/// are plain `<paragraph>` elements — is a foreign schema, and render returns
/// `None` for it rather than a lossy guess.
///
/// A `__type` the renderer doesn't recognize is handled differently: a
/// registered rule renders it; otherwise the node renders its text in a
/// `<p>`, so a Lexxy release that adds one stays readable.
pub fn render_segments<T: ReadTxn>(
    txn: &T,
    fragment: &XmlFragmentRef,
    rules: &Rules,
) -> Option<Vec<Segment>> {
    if !is_lexical_shaped(txn, fragment) {
        return None;
    }
    let mut em = Emitter::new();
    for node in fragment.children(txn) {
        match node {
            XmlOut::Text(t) => render_block_tree(txn, &t, &mut em, rules),
            XmlOut::Element(e) => render_decorator(txn, &e, &mut em, rules),
            // Fragments can't nest as children in yrs; escape the text as the
            // safe degradation for an exhaustive match.
            XmlOut::Fragment(f) => em.push_str(&escape_text(&f.get_string(txn))),
        }
    }
    Some(em.into_segments())
}

/// Rule-free rendering to a plain string — the fixture-parity surface most
/// tests pin. With no callback rules, segments always flatten.
#[cfg(test)]
pub fn render<T: ReadTxn>(txn: &T, fragment: &XmlFragmentRef) -> Option<String> {
    render_segments(txn, fragment, &Rules::empty()).map(|segs| {
        crate::render_rules::flatten(segs)
            .into_html()
            .expect("no callback rules registered")
    })
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

/// Walk a top-level block and everything under it on an explicit heap stack.
/// Container blocks push their children back as more work plus a close for
/// their end tag; leaf blocks render in full on the spot. The stack lives on
/// the heap, so nesting depth can't overflow the native call stack.
fn render_block_tree<T: ReadTxn>(txn: &T, root: &XmlTextRef, em: &mut Emitter, rules: &Rules) {
    let mut stack: Vec<Work> = vec![Work::Open(root.clone(), 0)];
    while let Some(work) = stack.pop() {
        match work {
            Work::Close(tag) => em.push_str(tag),
            Work::CloseOwned(tag) => em.push_str(&tag),
            Work::EndDeferred {
                node_type,
                attrs_json,
                child_types,
            } => {
                let content = em.end_frame();
                em.emit_deferred(node_type, attrs_json, child_types, content);
            }
            Work::Open(node, depth) => open_block(txn, &node, depth, em, &mut stack, rules),
        }
    }
}

/// Render one block. A registered rule wins over the built-in arms (so apps
/// can extend the schema or override a built-in); a container emits its
/// opening tag now and defers its children (and matching close) to the stack;
/// a leaf renders completely.
fn open_block<T: ReadTxn>(
    txn: &T,
    t: &XmlTextRef,
    depth: usize,
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
) {
    let ty = node_type(txn, t);
    if let Some(rule) = rules.nodes.get(ty.as_str()) {
        open_rule_block(txn, t, &ty, rule, depth, em, stack, rules);
        return;
    }
    match ty.as_str() {
        "paragraph" => {
            // An empty paragraph exports with a <br>, as Lexical's own
            // paragraph export does.
            em.begin_frame();
            render_inline(txn, t, 0, em, rules);
            let inline = em.end_frame();
            if inline.is_empty() {
                em.push_str("<p><br></p>");
            } else {
                em.push_str("<p>");
                em.append(inline);
                em.push_str("</p>");
            }
        }
        "heading" => {
            let tag = match str_attr(txn, t, "__tag").as_deref() {
                Some(tag @ ("h1" | "h2" | "h3" | "h4" | "h5" | "h6")) => tag.to_string(),
                _ => "h1".to_string(),
            };
            em.push('<');
            em.push_str(&tag);
            em.push('>');
            render_inline(txn, t, 0, em, rules);
            em.push_str("</");
            em.push_str(&tag);
            em.push('>');
        }
        "quote" => {
            em.push_str("<blockquote>");
            render_inline(txn, t, 0, em, rules);
            em.push_str("</blockquote>");
        }
        "code" => {
            // Code highlighting is derived state: token runs flatten to
            // plain text; linebreaks are <br>, tabs a wrapped \t.
            em.push_str("<pre");
            if let Some(lang) = str_attr(txn, t, "__language").filter(|l| !l.is_empty()) {
                em.push_str(" data-language=\"");
                em.push_str(&escape_attr(&lang));
                em.push('"');
            }
            em.push('>');
            render_inline(txn, t, 0, em, rules);
            em.push_str("</pre>");
        }
        "list" => {
            let tag = match str_attr(txn, t, "__tag").as_deref() {
                Some("ol") => "ol",
                _ => "ul",
            };
            em.push('<');
            em.push_str(tag);
            em.push('>');
            // Direct inline content is crafted-only (Lexxy puts none here);
            // keep it rather than drop it. Safe from double-render: this skips
            // block children, and push_block_children skips inline content.
            render_inline(txn, t, 0, em, rules);
            let close = if tag == "ol" { "</ol>" } else { "</ul>" };
            push_block_children(txn, t, depth, close, false, stack);
        }
        "listitem" => open_listitem(txn, t, depth, em, stack, rules),
        "table" => {
            em.push_str("<table><tbody>");
            render_inline(txn, t, 0, em, rules);
            push_block_children(txn, t, depth, "</tbody></table>", false, stack);
        }
        "tablerow" => {
            em.push_str("<tr>");
            render_inline(txn, t, 0, em, rules);
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
                em.push_str("<th>");
                "</th>"
            } else {
                em.push_str("<td>");
                "</td>"
            };
            render_inline(txn, t, 0, em, rules);
            push_block_children(txn, t, depth, close, false, stack);
        }
        // A block type this renderer doesn't know: degrade readably instead
        // of dropping content. A container's block children render with no
        // invented wrapper (a Lexxy table wrapper's rows still come out as
        // rows); a leaf's text becomes a plain paragraph.
        _ => {
            if !block_children(txn, t).is_empty() {
                render_inline(txn, t, 0, em, rules);
                push_block_children(txn, t, depth, "", false, stack);
            } else {
                em.begin_frame();
                render_inline(txn, t, 0, em, rules);
                let inline = em.end_frame();
                if !inline.is_empty() {
                    em.push_str("<p>");
                    em.append(inline);
                    em.push_str("</p>");
                }
            }
        }
    }
}

/// Render a block through a registered rule. Declarative rules emit the tag,
/// resolved attributes, and template text here; callback rules capture their
/// children into a frame and defer the markup to the Ruby layer.
#[allow(clippy::too_many_arguments)]
fn open_rule_block<T: ReadTxn>(
    txn: &T,
    t: &XmlTextRef,
    ty: &str,
    rule: &NodeRule,
    depth: usize,
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
) {
    if rule.callback {
        em.begin_frame();
        // Children render into the frame; EndDeferred seals it. Blocks go via
        // the stack (pushed above the marker, so they complete first); inline
        // content renders now — in blocks mode too, since a block like a list
        // item holds its own text alongside its nested blocks.
        stack.push(Work::EndDeferred {
            node_type: ty.to_string(),
            attrs_json: xml_attrs_json(txn, t),
            child_types: text_child_types(txn, t),
        });
        match rule.content {
            Content::Inline => render_inline(txn, t, 0, em, rules),
            Content::Blocks => {
                render_inline(txn, t, 0, em, rules);
                for child in block_children(txn, t).into_iter().rev() {
                    if depth < MAX_BLOCK_DEPTH {
                        stack.push(Work::Open(child, depth + 1));
                    }
                }
            }
            Content::None => {}
        }
        return;
    }

    let tag = rule.tag.as_deref().unwrap_or("div");
    em.push('<');
    em.push_str(tag);
    for (name, parts) in &rule.attrs {
        if let Some(value) = resolve_parts(parts, |r| xml_ref_attr(txn, t, r)) {
            em.push(' ');
            em.push_str(name);
            em.push_str("=\"");
            em.push_str(&escape_attr(&value));
            em.push('"');
        }
    }
    em.push('>');
    if rule.void {
        return;
    }
    if let Some(text) = &rule.text {
        if let Some(value) = resolve_parts(text, |r| xml_ref_attr(txn, t, r)) {
            em.push_str(&escape_text(&value));
        }
    }
    match rule.content {
        Content::Inline => {
            render_inline(txn, t, 0, em, rules);
            em.push_str("</");
            em.push_str(tag);
            em.push('>');
        }
        Content::Blocks => {
            render_inline(txn, t, 0, em, rules);
            stack.push(Work::CloseOwned(format!("</{tag}>")));
            if depth < MAX_BLOCK_DEPTH {
                for child in block_children(txn, t).into_iter().rev() {
                    stack.push(Work::Open(child, depth + 1));
                }
            }
        }
        Content::None => {
            em.push_str("</");
            em.push_str(tag);
            em.push('>');
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
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
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

    em.push_str("<li");
    if let Some(c) = checked {
        em.push_str(" aria-checked=\"");
        em.push_str(if c { "true" } else { "false" });
        em.push('"');
    }
    em.push_str(" value=\"");
    em.push_str(&value.to_string());
    em.push('"');
    em.push('>');
    // Inline content first, then any nested list blocks (Lexical stores the
    // nested list as a child of the item).
    render_inline(txn, t, 0, em, rules);
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

/// The `__type` of every element/block child of a block, in document order —
/// handed to callback rules as `node.child_types` (a gallery's image count,
/// a list item's nested list). Text runs and metadata maps are not children.
fn text_child_types<T: ReadTxn>(txn: &T, t: &XmlTextRef) -> Vec<String> {
    let mut out = Vec::new();
    for d in t.diff(txn, YChange::identity) {
        match d.insert {
            Out::YXmlText(child) => out.push(node_type(txn, &child)),
            Out::YXmlElement(child) => out.push(elem_type(txn, &child)),
            _ => {}
        }
    }
    out
}

/// Render a block's inline content: formatted text runs, linebreaks, tabs,
/// links, and inline decorators. Nested block children are NOT rendered here
/// (the block renderers handle them), so a list item's text doesn't duplicate
/// its nested list. `depth` counts inline-link nesting only (a link's body is
/// itself inline content); past `MAX_INLINE_DEPTH` a link renders as flat text,
/// capping the recursion.
fn render_inline<T: ReadTxn>(
    txn: &T,
    t: &XmlTextRef,
    depth: usize,
    em: &mut Emitter,
    rules: &Rules,
) {
    // Format carries from the metadata Map that precedes each run. Lexxy always
    // emits one Map immediately before its run, so this is exact; a run with no
    // preceding Map would inherit the previous run's format (wrong, but only
    // reachable from a doc Lexxy didn't produce).
    let mut format: u32 = 0;
    let mut style = String::new();
    let mut is_tab = false;
    for d in t.diff(txn, YChange::identity) {
        match d.insert {
            Out::YMap(m) => {
                let ty = match m.get(txn, "__type") {
                    Some(Out::Any(Any::String(s))) => s.to_string(),
                    _ => String::new(),
                };
                match ty.as_str() {
                    "linebreak" => em.push_str("<br>"),
                    "tab" => {
                        is_tab = true;
                        format = 0;
                        style.clear();
                    }
                    // "text", "code-highlight", and anything metadata-shaped:
                    // read the format bits and style for the run that follows.
                    _ => {
                        is_tab = false;
                        format = match m.get(txn, "__format") {
                            Some(Out::Any(Any::Number(n))) => n as u32,
                            Some(Out::Any(Any::BigInt(n))) => n as u32,
                            _ => 0,
                        };
                        style = match m.get(txn, "__style") {
                            Some(Out::Any(Any::String(s))) => s.to_string(),
                            _ => String::new(),
                        };
                    }
                }
            }
            Out::Any(Any::String(s)) => {
                if is_tab {
                    // Lexxy exports a tab as a literal \t in a span.
                    em.push_str("<span>\t</span>");
                    is_tab = false;
                } else {
                    em.push_str(&render_run(&s, format, &style));
                }
            }
            Out::YXmlText(child) => {
                let ty = node_type(txn, &child);
                if is_inline_type(&ty) {
                    render_link(txn, &child, depth, em, rules);
                }
                // Nested blocks are rendered by their parent block's renderer.
            }
            Out::YXmlElement(e) => render_inline_decorator(txn, &e, em, rules),
            _ => {}
        }
    }
}

/// One text run with Lexical's format bitmask, as Lexxy's exporter wraps it.
fn render_run(text: &str, format: u32, style: &str) -> String {
    let mut html = escape_text(text);
    // A run's __style survives export only on a real createDOM tag (colors
    // from Lexxy's highlight dropdown). The style attribute rides the OUTER
    // tag when one exists, else the inner tag; a plain or s/u-only run's span
    // is unwrapped, and the style dies with it — all captured behavior.
    let css = lexxy_style(style);
    let outer_tag = if format & FMT_CODE != 0 {
        Some("code")
    } else if format & FMT_HIGHLIGHT != 0 {
        Some("mark")
    } else if format & FMT_SUBSCRIPT != 0 {
        Some("sub")
    } else if format & FMT_SUPERSCRIPT != 0 {
        Some("sup")
    } else {
        None
    };

    // Inner semantic tag (createDOM): strong for bold, em for italic-only.
    // A plain run's span is unwrapped, leaving bare text.
    let inner_style = if outer_tag.is_none() {
        css.as_deref()
    } else {
        None
    };
    if format & FMT_BOLD != 0 {
        html = format_wrap(html, "strong", inner_style);
    } else if format & FMT_ITALIC != 0 {
        html = format_wrap(html, "em", inner_style);
    }
    // Outer semantic tag (createDOM): first match wins.
    if let Some(tag) = outer_tag {
        html = format_wrap(html, tag, css.as_deref());
    }
    // Lexxy's wrap pass: <i> only when italic couldn't claim the inner tag
    // (bold took it); <b> never fires (bold always claims strong); <s>/<u>
    // always wrap.
    if format & FMT_ITALIC != 0 && format & FMT_BOLD != 0 {
        html = format_wrap(html, "i", None);
    }
    if format & FMT_STRIKETHROUGH != 0 {
        html = format_wrap(html, "s", None);
    }
    if format & FMT_UNDERLINE != 0 {
        html = format_wrap(html, "u", None);
    }
    html
}

fn format_wrap(inner: String, tag: &str, style: Option<&str>) -> String {
    match style {
        Some(css) => format!("<{tag} style=\"{}\">{inner}</{tag}>", escape_attr(css)),
        None => format!("<{tag}>{inner}</{tag}>"),
    }
}

/// Filter a run's `__style` to what Lexxy's sanitize lets through — `color`
/// and `background-color` — keeping source order, serialized the way the
/// sanitize hook rebuilds it: `prop: value;` with no separator between
/// properties. Everything else (text-transform, white-space, smuggled
/// properties) is stripped, matching the captured value output.
fn lexxy_style(style: &str) -> Option<String> {
    let mut css = String::new();
    for decl in style.split(';') {
        let Some((prop, value)) = decl.split_once(':') else {
            continue;
        };
        let (prop, value) = (prop.trim(), value.trim());
        if (prop == "color" || prop == "background-color") && !value.is_empty() {
            css.push_str(prop);
            css.push_str(": ");
            css.push_str(value);
            css.push(';');
        }
    }
    if css.is_empty() {
        None
    } else {
        Some(css)
    }
}

/// `link` / `autolink`: Lexxy's sanitize keeps only `href` and `title`
/// (`target`/`rel` are stored in the doc but stripped from exported HTML).
fn render_link<T: ReadTxn>(txn: &T, t: &XmlTextRef, depth: usize, em: &mut Emitter, rules: &Rules) {
    em.push_str("<a");
    if let Some(url) = str_attr(txn, t, "__url") {
        em.push_str(" href=\"");
        em.push_str(&escape_attr(&url));
        em.push('"');
    }
    if let Some(title) = str_attr(txn, t, "__title").filter(|s| !s.is_empty()) {
        em.push_str(" title=\"");
        em.push_str(&escape_attr(&title));
        em.push('"');
    }
    em.push('>');
    if depth < MAX_INLINE_DEPTH {
        render_inline(txn, t, depth + 1, em, rules);
    } else {
        // A link chain nested past the cap (only crafted input reaches here):
        // keep its text, drop any further link structure.
        em.push_str(&escape_text(&t.get_string(txn)));
    }
    em.push_str("</a>");
}

/// Root-level decorators: horizontal rule and upload attachments. Registered
/// rules win here too, so custom decorator elements render or defer.
fn render_decorator<T: ReadTxn>(txn: &T, e: &XmlElementRef, em: &mut Emitter, rules: &Rules) {
    let ty = elem_type(txn, e);
    if let Some(rule) = rules.nodes.get(ty.as_str()) {
        render_rule_element(txn, e, &ty, rule, em);
        return;
    }
    // Core Lexical's only decorator; unknown decorators render nothing
    // (nothing extractable without a rule).
    if ty == "horizontalrule" {
        em.push_str("<hr>");
    }
}

/// Inline decorators (inside a paragraph): mention/embed attachments.
fn render_inline_decorator<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    em: &mut Emitter,
    rules: &Rules,
) {
    render_decorator(txn, e, em, rules)
}

/// A decorator element rendered through a registered rule. Decorators are
/// childless in practice, so declarative rules render tag + attrs + template
/// text (content slots are ignored) and callback rules defer with empty
/// content.
fn render_rule_element<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    ty: &str,
    rule: &NodeRule,
    em: &mut Emitter,
) {
    if rule.callback {
        em.emit_deferred(
            ty.to_string(),
            xml_attrs_json(txn, e),
            Vec::new(),
            Vec::new(),
        );
        return;
    }
    let tag = rule.tag.as_deref().unwrap_or("div");
    em.push('<');
    em.push_str(tag);
    for (name, parts) in &rule.attrs {
        if let Some(value) = resolve_parts(parts, |r| xml_ref_attr(txn, e, r)) {
            em.push(' ');
            em.push_str(name);
            em.push_str("=\"");
            em.push_str(&escape_attr(&value));
            em.push('"');
        }
    }
    em.push('>');
    if rule.void {
        return;
    }
    if let Some(text) = &rule.text {
        if let Some(value) = resolve_parts(text, |r| xml_ref_attr(txn, e, r)) {
            em.push_str(&escape_text(&value));
        }
    }
    em.push_str("</");
    em.push_str(tag);
    em.push('>');
}

fn elem_type<T: ReadTxn>(txn: &T, e: &XmlElementRef) -> String {
    match e.get_attribute(txn, "__type") {
        Some(Out::Any(Any::String(s))) => s.to_string(),
        _ => String::new(),
    }
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

    /// Core rendering of the captured full-schema document, pinned as a
    /// golden (`.core.html`). Stock Lexical has no canonical serializer to
    /// capture against, so this is a self-pinned regression guard; the
    /// external truth — byte parity with a real Lexxy editor's value — is
    /// held at the Ruby layer, where `Y::Lexxy::NODES` completes the schema.
    /// The pair was captured together from one live
    /// editor session: `lexxy_full.bin` is the synced Yjs state, `lexxy_full.html`
    /// is `lexxy-editor.value` for the same document. It covers every block and
    /// format the schema map handles.
    #[test]
    fn core_rendering_of_the_full_fixture_is_pinned() {
        let bytes = include_bytes!("fixtures/lexxy_full.bin");
        let expected = include_str!("fixtures/lexxy_full.core.html");
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
    fn core_rendering_of_the_torture_fixture_is_pinned() {
        let bytes = include_bytes!("fixtures/lexxy_torture.bin");
        let expected = include_str!("fixtures/lexxy_torture.core.html");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let html = render(&txn, &frag).unwrap();
        assert_eq!(html, expected.trim_end());

        // The golden already proves these; name the load-bearing core
        // structures so a regression fails with the one it broke. (The
        // fixture's Lexxy-only nodes — attachments, its code type — are
        // covered at the Ruby layer, where the Lexxy rules render them.)
        for (what, probe) in [
            ("list nested in a table cell", "<td><ul><li"),
            ("quote in a table cell", "<td><blockquote>"),
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
                "whitespace-only paragraphs",
                "<p><span>\t</span></p><p><br></p><p><br></p>",
            ),
        ] {
            assert!(html.contains(probe), "{what}: missing {probe}");
        }
    }

    /// Highlight colors (captured live): a run's __style survives on the
    /// createDOM tag — the outer tag when present, else the inner — filtered
    /// to color/background-color; plain and s/u-only runs lose it with their
    /// unwrapped span. The fixture's byte-for-byte match pins both the keeps
    /// and the drops.
    #[test]
    fn renders_the_captured_styles_document_byte_for_byte() {
        let bytes = include_bytes!("fixtures/lexxy_styles.bin");
        let expected = include_str!("fixtures/lexxy_styles.html");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        assert_eq!(render(&txn, &frag).unwrap(), expected.trim_end());
    }

    #[test]
    fn run_styles_ride_the_createdom_tag() {
        // Outer tag takes the style over the inner one.
        assert_eq!(
            render_run("x", 128, "background-color: var(--highlight-bg-2);"),
            "<mark style=\"background-color: var(--highlight-bg-2);\">x</mark>"
        );
        assert_eq!(
            render_run("x", 1 | 128, "background-color: red;"),
            "<mark style=\"background-color: red;\"><strong>x</strong></mark>"
        );
        // No outer tag: the inner takes it.
        assert_eq!(
            render_run("x", 1, "color: red;"),
            "<strong style=\"color: red;\">x</strong>"
        );
        // Plain and s/u-only runs lose the style with their unwrapped span.
        assert_eq!(render_run("x", 0, "color: red;"), "x");
        assert_eq!(render_run("x", 4, "color: red;"), "<s>x</s>");
        // Two properties: source order, no separator between them.
        assert_eq!(
            render_run("x", 128, "color: red; background-color: blue;"),
            "<mark style=\"color: red;background-color: blue;\">x</mark>"
        );
        // Disallowed properties are stripped; quotes in values escape.
        assert_eq!(
            render_run("x", 128, "font-size: 40px; color: r\"ed;"),
            "<mark style=\"color: r&quot;ed;\">x</mark>"
        );
    }

    /// A known container with inline content jammed directly into it
    /// (Lexxy never does this) keeps the content instead of dropping it.
    #[test]
    fn a_known_container_keeps_stray_inline_content() {
        use yrs::{XmlFragment, XmlTextPrelim};
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("root");
        {
            let mut txn = doc.transact_mut();
            let list = frag.push_back(&mut txn, XmlTextPrelim::new("stray"));
            list.insert_attribute(&mut txn, "__type", "list");
            list.insert_attribute(&mut txn, "__tag", "ul");
            let li = list.insert_embed(&mut txn, 5, XmlTextPrelim::new("item"));
            li.insert_attribute(&mut txn, "__type", "listitem");
        }
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let html = render(&txn, &frag).unwrap();

        assert!(html.contains("stray"), "stray inline text kept: {html}");
        assert!(html.contains("<li value=\"1\">item</li>"), "{html}");
    }

    /// Lexxy-only nodes (this fixture is a gallery of attachments between
    /// two paragraphs) are unknown to the core schema and degrade readably —
    /// the paragraphs survive, the gallery renders nothing rather than
    /// garbage. The Ruby layer's Lexxy rules render it fully; the Ruby
    /// fixture tests pin that byte for byte.
    #[test]
    fn core_degrades_lexxy_only_nodes_readably() {
        let bytes = include_bytes!("fixtures/lexxy_gallery.bin");
        let expected = include_str!("fixtures/lexxy_gallery.core.html");
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("root").unwrap();
        let html = render(&txn, &frag).unwrap();
        assert_eq!(html, expected.trim_end());
        assert!(html.contains("<p>Before gallery</p>"));
    }

    #[test]
    fn format_runs_match_lexxys_export_algorithm() {
        // Singles take their semantic tag; the span for plain text unwraps.
        assert_eq!(render_run("x", 0, ""), "x");
        assert_eq!(render_run("x", 1, ""), "<strong>x</strong>");
        assert_eq!(render_run("x", 2, ""), "<em>x</em>");
        assert_eq!(render_run("x", 4, ""), "<s>x</s>");
        assert_eq!(render_run("x", 8, ""), "<u>x</u>");
        assert_eq!(render_run("x", 16, ""), "<code>x</code>");
        assert_eq!(render_run("x", 32, ""), "<sub>x</sub>");
        assert_eq!(render_run("x", 64, ""), "<sup>x</sup>");
        assert_eq!(render_run("x", 128, ""), "<mark>x</mark>");
        // bold+italic: bold claims the inner tag, italic falls back to <i>.
        assert_eq!(render_run("x", 3, ""), "<i><strong>x</strong></i>");
        // Wrap order: u outside s outside the semantic core.
        assert_eq!(render_run("x", 4 | 8, ""), "<u><s>x</s></u>");
        assert_eq!(render_run("x", 1 | 8, ""), "<u><strong>x</strong></u>");
        // Outer tag composes with the inner one.
        assert_eq!(
            render_run("x", 1 | 16, ""),
            "<code><strong>x</strong></code>"
        );
        assert_eq!(render_run("x", 2 | 128, ""), "<mark><em>x</em></mark>");
        // Everything at once: u(s(i(outer(inner)))).
        assert_eq!(
            render_run("x", 1 | 2 | 4 | 8 | 16, ""),
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
