//! Native HTML rendering of ProseMirror/Tiptap documents from the yrs collab
//! structure — no Node process, no headless editor.
//!
//! The y-prosemirror binding stores a document in a Y.XmlFragment: block nodes
//! are Y.XmlElement (the tag is the node type, its attributes are the node
//! attrs), and text is Y.XmlText whose per-run formatting attributes are the
//! marks. Node and mark names come from the editor's schema, so this accepts
//! both spellings in use: Tiptap's camelCase (`bulletList`, `bold`) and the
//! prosemirror-schema-basic snake_case (`bullet_list`, `strong`).
//!
//! Output follows `ueberdosis/tiptap-php` (the maintained PHP renderer for
//! ProseMirror JSON) and matches Tiptap's own `getHTML()` byte for byte on the
//! captured fixtures — including mentions — with one deliberate exception: a
//! table renders as the semantic `<table><tbody>…`, without the
//! `<colgroup>`/`min-width` styling Tiptap's editor view injects (tiptap-php
//! drops it too). The details family follows tiptap-php's renderHTML, since
//! that Tiptap extension is Pro-only.
//!
//! Marks nest in a fixed order (outermost first): link, bold, italic, strike,
//! underline, highlight, then subscript/superscript. `code` excludes every
//! other mark, so a code run is just `<code>`.
//!
//! Custom nodes and marks: apps register rules by node type and mark name
//! (see `render_rules`). A node rule is consulted before the built-in arms, so
//! it can extend the schema or override a built-in; a mark rule claims its
//! mark from the built-in wraps and wraps outside everything, link included.
//! Declarative rules render here; callback rules emit `Segment::Pending` for
//! the Ruby layer to fill in after the render.

use crate::render_rules::{
    any_attr_string, resolve_parts, xml_attrs_json, xml_ref_attr, Content, Emitter, MarkRule,
    NodeRule, Rules, Segment,
};
use yrs::types::text::YChange;
use yrs::types::Attrs;
use yrs::{
    Any, GetString, Out, ReadTxn, Text, Xml, XmlElementRef, XmlFragment, XmlFragmentRef, XmlOut,
    XmlTextRef,
};

// The block tree is walked on a heap stack, so depth costs memory, not native
// stack frames; this caps the work a pathological document can demand.
const MAX_DEPTH: usize = 1024;

/// A pending block on the traversal stack. `Open` renders a node (pushing its
/// block children as more work); `Close` and `CloseOwned` emit a container's
/// end tag once its children are done (built-in containers close with fixed
/// strings; rule containers close with their computed tag). `EndPending` seals
/// a callback node: it pops the emitter frame its children rendered into and
/// emits the pending segment.
enum Work {
    Open(XmlElementRef, usize),
    Close(&'static str),
    CloseOwned(String),
    EndPending { ty: String, attrs_json: String },
}

/// Render a ProseMirror/Tiptap-shaped XML root to segments, or `None` when the
/// root isn't ProseMirror-shaped. ProseMirror blocks are plain Y.XmlElement
/// tags; a Lexical root (Y.XmlText children carrying a `__type`) is a
/// different schema and returns `None` instead of a garbled render.
pub fn render_segments<T: ReadTxn>(
    txn: &T,
    fragment: &XmlFragmentRef,
    rules: &Rules,
) -> Option<Vec<Segment>> {
    if !is_prosemirror_shaped(txn, fragment) {
        return None;
    }
    let mut em = Emitter::new();
    for node in fragment.children(txn) {
        match node {
            XmlOut::Element(e) => render_block_tree(txn, &e, &mut em, rules),
            // y-prosemirror never writes a bare text run at the root, but a
            // crafted doc can; render it rather than drop it.
            XmlOut::Text(t) => render_text_runs(txn, &t, &mut em, rules),
            // Fragments can't nest as children in yrs, so this arm shouldn't
            // be reachable; it exists because the match must be exhaustive,
            // and escaping the text is the safe degradation.
            XmlOut::Fragment(f) => em.push_str(&escape_text(&f.get_string(txn))),
        }
    }
    Some(em.into_segments())
}

/// Rule-free rendering to a plain string — the fixture-parity surface most
/// tests pin. With no callback rules, segments always flatten.
#[cfg(test)]
pub fn render<T: ReadTxn>(txn: &T, fragment: &XmlFragmentRef) -> Option<String> {
    render_segments(txn, fragment, &Rules::empty())
        .map(|segs| crate::render_rules::flatten(segs).unwrap_or_default())
}

/// A root is ProseMirror-shaped when it's empty or its first child is a block
/// element with no `__type` (Lexical stamps `__type` on every node; ProseMirror
/// uses the node type as the element tag).
fn is_prosemirror_shaped<T: ReadTxn>(txn: &T, fragment: &XmlFragmentRef) -> bool {
    match fragment.children(txn).next() {
        Some(XmlOut::Element(e)) => e.get_attribute(txn, "__type").is_none(),
        Some(_) => false, // Lexical stores blocks as XmlText
        None => true,     // empty document
    }
}

/// Walk one top-level block and everything under it on a heap stack.
fn render_block_tree<T: ReadTxn>(txn: &T, root: &XmlElementRef, em: &mut Emitter, rules: &Rules) {
    let mut stack: Vec<Work> = vec![Work::Open(root.clone(), 0)];
    while let Some(work) = stack.pop() {
        match work {
            Work::Close(tag) => em.push_str(tag),
            Work::CloseOwned(tag) => em.push_str(&tag),
            Work::EndPending { ty, attrs_json } => {
                let content = em.end_frame();
                em.emit_pending(ty, attrs_json, content);
            }
            Work::Open(node, depth) => open_block(txn, &node, depth, em, &mut stack, rules),
        }
    }
}

/// Render one block. A registered rule wins over the built-in arms (so apps
/// can extend the schema or override a built-in). Text blocks (paragraph,
/// heading, code) render in full on the spot; container blocks emit their
/// opening tag and defer their children (and matching `Close`) to the stack.
fn open_block<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    depth: usize,
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
) {
    if let Some(rule) = rules.nodes.get(e.tag().as_ref()) {
        open_rule_block(txn, e, rule, depth, em, stack, rules);
        return;
    }
    match e.tag().as_ref() {
        "paragraph" => {
            em.push_str("<p>");
            render_inline(txn, e, 0, em, rules);
            em.push_str("</p>");
        }
        "heading" => {
            let level = num_attr(txn, e, "level").unwrap_or(1).clamp(1, 6);
            let tag = ['1', '2', '3', '4', '5', '6'][(level - 1) as usize];
            em.push_str("<h");
            em.push(tag);
            em.push('>');
            render_inline(txn, e, 0, em, rules);
            em.push_str("</h");
            em.push(tag);
            em.push('>');
        }
        "codeBlock" | "code_block" => {
            em.push_str("<pre><code");
            if let Some(lang) = str_attr(txn, e, "language").filter(|l| !l.is_empty()) {
                em.push_str(" class=\"language-");
                em.push_str(&escape_attr(&lang));
                em.push('"');
            }
            em.push('>');
            em.push_str(&escape_text(&code_text(txn, e)));
            em.push_str("</code></pre>");
        }
        "blockquote" => open_container(
            txn,
            e,
            depth,
            "<blockquote>",
            "</blockquote>",
            em,
            stack,
            rules,
        ),
        "bulletList" | "bullet_list" => {
            open_container(txn, e, depth, "<ul>", "</ul>", em, stack, rules)
        }
        "orderedList" | "ordered_list" => {
            match num_attr(txn, e, "start") {
                Some(start) if start != 1 => {
                    em.push_str("<ol start=\"");
                    em.push_str(&start.to_string());
                    em.push_str("\">");
                }
                _ => em.push_str("<ol>"),
            }
            push_block_children(txn, e, depth, "</ol>", em, stack, rules);
        }
        "listItem" | "list_item" => {
            open_container(txn, e, depth, "<li>", "</li>", em, stack, rules)
        }
        "taskList" | "task_list" => open_container(
            txn,
            e,
            depth,
            "<ul data-type=\"taskList\">",
            "</ul>",
            em,
            stack,
            rules,
        ),
        "taskItem" | "task_item" => {
            let checked = bool_attr(txn, e, "checked");
            em.push_str("<li data-checked=\"");
            em.push_str(if checked { "true" } else { "false" });
            em.push_str("\" data-type=\"taskItem\"><label><input type=\"checkbox\"");
            if checked {
                em.push_str(" checked=\"checked\"");
            }
            em.push_str("><span></span></label><div>");
            push_block_children(txn, e, depth, "</div></li>", em, stack, rules);
        }
        "table" => {
            em.push_str("<table><tbody>");
            push_block_children(txn, e, depth, "</tbody></table>", em, stack, rules);
        }
        "tableRow" | "table_row" => {
            open_container(txn, e, depth, "<tr>", "</tr>", em, stack, rules)
        }
        "tableHeader" | "table_header" => open_cell(txn, e, depth, "th", "</th>", em, stack, rules),
        "tableCell" | "table_cell" => open_cell(txn, e, depth, "td", "</td>", em, stack, rules),
        // The details family follows tiptap-php (the extension is Tiptap Pro,
        // so there's no free getHTML() to capture against).
        "details" => {
            let open = if bool_attr(txn, e, "open") {
                "<details open=\"open\">"
            } else {
                "<details>"
            };
            open_container(txn, e, depth, open, "</details>", em, stack, rules);
        }
        "detailsSummary" | "details_summary" => {
            em.push_str("<summary>");
            render_inline(txn, e, 0, em, rules);
            em.push_str("</summary>");
        }
        "detailsContent" | "details_content" => open_container(
            txn,
            e,
            depth,
            "<div data-type=\"detailsContent\">",
            "</div>",
            em,
            stack,
            rules,
        ),
        "horizontalRule" | "horizontal_rule" => em.push_str("<hr>"),
        "image" => render_image(txn, e, em),
        "hardBreak" | "hard_break" => em.push_str("<br>"),
        // Unknown block: keep its content rather than dropping it. If it holds
        // child blocks, render them with no wrapper; otherwise treat it as a
        // text block.
        _ => {
            if has_element_child(txn, e) {
                // Renders its direct text runs, then the children, with no
                // invented wrapper tags.
                push_block_children(txn, e, depth, "", em, stack, rules);
            } else {
                em.begin_frame();
                render_inline(txn, e, 0, em, rules);
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
    e: &XmlElementRef,
    rule: &NodeRule,
    depth: usize,
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
) {
    let ty = e.tag().to_string();
    if rule.callback {
        em.begin_frame();
        // Children render into the frame; EndPending seals it. Blocks go via
        // the stack (pushed above the marker, so they complete first); inline
        // content renders now.
        stack.push(Work::EndPending {
            ty,
            attrs_json: xml_attrs_json(txn, e),
        });
        match rule.content {
            Content::Inline => render_inline(txn, e, 0, em, rules),
            Content::Blocks => {
                render_stray_text(txn, e, em, rules);
                if depth < MAX_DEPTH {
                    for child in element_children(txn, e).into_iter().rev() {
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
    match rule.content {
        Content::Inline => {
            render_inline(txn, e, 0, em, rules);
            em.push_str("</");
            em.push_str(tag);
            em.push('>');
        }
        Content::Blocks => {
            render_stray_text(txn, e, em, rules);
            stack.push(Work::CloseOwned(format!("</{tag}>")));
            if depth < MAX_DEPTH {
                for child in element_children(txn, e).into_iter().rev() {
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

#[allow(clippy::too_many_arguments)]
fn open_container<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    depth: usize,
    open: &str,
    close: &'static str,
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
) {
    em.push_str(open);
    push_block_children(txn, e, depth, close, em, stack, rules);
}

/// A table cell: `<th>`/`<td>` carrying colspan/rowspan (default 1, always
/// emitted, matching Tiptap).
#[allow(clippy::too_many_arguments)]
fn open_cell<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    depth: usize,
    tag: &str,
    close: &'static str,
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
) {
    em.push('<');
    em.push_str(tag);
    em.push_str(" colspan=\"");
    em.push_str(&num_attr(txn, e, "colspan").unwrap_or(1).to_string());
    em.push_str("\" rowspan=\"");
    em.push_str(&num_attr(txn, e, "rowspan").unwrap_or(1).to_string());
    em.push_str("\">");
    push_block_children(txn, e, depth, close, em, stack, rules);
}

/// Defer a node's child *elements* onto the stack, closing tag below them, so
/// they render in order and the tag closes after. Any direct text runs render
/// first: schema-valid documents never put bare text in a container, but a
/// crafted one can, and dropping it would lose content. Past `MAX_DEPTH` the
/// children are dropped but the tag still closes, keeping the output well
/// formed.
#[allow(clippy::too_many_arguments)]
fn push_block_children<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    depth: usize,
    close: &'static str,
    em: &mut Emitter,
    stack: &mut Vec<Work>,
    rules: &Rules,
) {
    render_stray_text(txn, e, em, rules);
    stack.push(Work::Close(close));
    if depth >= MAX_DEPTH {
        return;
    }
    for child in element_children(txn, e).into_iter().rev() {
        stack.push(Work::Open(child, depth + 1));
    }
}

/// Direct text runs jammed into a container (schema-valid documents have
/// none); rendered rather than dropped.
fn render_stray_text<T: ReadTxn>(txn: &T, e: &XmlElementRef, em: &mut Emitter, rules: &Rules) {
    for node in e.children(txn) {
        if let XmlOut::Text(t) = node {
            render_text_runs(txn, &t, em, rules);
        }
    }
}

fn element_children<T: ReadTxn>(txn: &T, e: &XmlElementRef) -> Vec<XmlElementRef> {
    e.children(txn)
        .filter_map(|c| match c {
            XmlOut::Element(el) => Some(el),
            _ => None,
        })
        .collect()
}

/// Render a text block's inline content: text runs (with their marks) and
/// inline element nodes (hard breaks, mentions, inline images). A registered
/// rule wins over the built-in inline nodes here too. An unknown inline node
/// keeps its text instead of vanishing; `depth` caps that recursion on a
/// crafted nest of unknowns.
fn render_inline<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    depth: usize,
    em: &mut Emitter,
    rules: &Rules,
) {
    for node in e.children(txn) {
        match node {
            XmlOut::Text(t) => render_text_runs(txn, &t, em, rules),
            XmlOut::Element(child) => {
                if let Some(rule) = rules.nodes.get(child.tag().as_ref()) {
                    render_rule_inline(txn, &child, rule, depth, em, rules);
                    continue;
                }
                match child.tag().as_ref() {
                    "hardBreak" | "hard_break" => em.push_str("<br>"),
                    "image" => render_image(txn, &child, em),
                    "mention" => render_mention(txn, &child, em),
                    _ => {
                        if depth < MAX_DEPTH {
                            render_inline(txn, &child, depth + 1, em, rules);
                        }
                    }
                }
            }
            XmlOut::Fragment(_) => {}
        }
    }
}

/// A rule node in inline position (inside a text block). Unlike Lexical's
/// childless decorators, a ProseMirror inline node can hold real content, so
/// the content slot renders — as inline content, since there are no blocks
/// inside a text block (`content: blocks` behaves like `inline` here).
fn render_rule_inline<T: ReadTxn>(
    txn: &T,
    e: &XmlElementRef,
    rule: &NodeRule,
    depth: usize,
    em: &mut Emitter,
    rules: &Rules,
) {
    if rule.callback {
        em.begin_frame();
        if rule.content != Content::None && depth < MAX_DEPTH {
            render_inline(txn, e, depth + 1, em, rules);
        }
        let content = em.end_frame();
        em.emit_pending(e.tag().to_string(), xml_attrs_json(txn, e), content);
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
    if rule.content != Content::None && depth < MAX_DEPTH {
        render_inline(txn, e, depth + 1, em, rules);
    }
    em.push_str("</");
    em.push_str(tag);
    em.push('>');
}

/// A mention, as Tiptap's Mention extension serializes it (no app-configured
/// HTMLAttributes): `data-type`, `data-id`, `data-label` when present, the
/// suggestion char, and `@label` (falling back to `@id`) as the text.
fn render_mention<T: ReadTxn>(txn: &T, e: &XmlElementRef, em: &mut Emitter) {
    let id = str_attr(txn, e, "id");
    let label = str_attr(txn, e, "label");
    let char = str_attr(txn, e, "mentionSuggestionChar").unwrap_or_else(|| "@".to_string());
    em.push_str("<span data-type=\"mention\"");
    if let Some(id) = &id {
        em.push_str(" data-id=\"");
        em.push_str(&escape_attr(id));
        em.push('"');
    }
    if let Some(label) = &label {
        em.push_str(" data-label=\"");
        em.push_str(&escape_attr(label));
        em.push('"');
    }
    em.push_str(" data-mention-suggestion-char=\"");
    em.push_str(&escape_attr(&char));
    em.push_str("\">");
    em.push_str(&escape_text(&char));
    em.push_str(&escape_text(&label.or(id).unwrap_or_default()));
    em.push_str("</span>");
}

/// Emit each formatted run of a Y.XmlText.
fn render_text_runs<T: ReadTxn>(txn: &T, t: &XmlTextRef, em: &mut Emitter, rules: &Rules) {
    for d in t.diff(txn, YChange::identity) {
        if let Out::Any(Any::String(s)) = &d.insert {
            em.push_str(&render_run(s, d.attributes.as_deref(), rules));
        }
    }
}

/// Wrap one text run in its marks, nesting innermost-first:
/// subscript/superscript, highlight, underline, strike, italic, bold, a
/// textStyle span, then link on the outside. `code` renders alone among the
/// formatting marks (Tiptap's Code mark excludes them all), but a link still
/// wraps it — Tiptap can't produce code+link, prosemirror-schema-basic can,
/// and dropping the link would lose the href.
///
/// A registered mark rule claims its stored name from the built-in wraps
/// (overriding it) and wraps outside everything; multiple custom marks nest
/// alphabetically by name, so output is deterministic regardless of
/// registration order.
fn render_run(text: &str, marks: Option<&Attrs>, rules: &Rules) -> String {
    let mut html = escape_text(text);
    let Some(marks) = marks else {
        return html;
    };
    if has(marks, &["code"], rules) {
        html = wrap(html, "code");
    } else {
        if has(marks, &["subscript", "sub"], rules) {
            html = wrap(html, "sub");
        } else if has(marks, &["superscript", "sup"], rules) {
            html = wrap(html, "sup");
        }
        if has(marks, &["highlight"], rules) {
            html = wrap(html, "mark");
        }
        if has(marks, &["underline", "u"], rules) {
            html = wrap(html, "u");
        }
        if has(marks, &["strike", "s"], rules) {
            html = wrap(html, "s");
        }
        if has(marks, &["italic", "em"], rules) {
            html = wrap(html, "em");
        }
        if has(marks, &["bold", "strong"], rules) {
            html = wrap(html, "strong");
        }
        if !rules.marks.contains_key("textStyle") {
            if let Some(Any::Map(style)) = marks.get("textStyle") {
                let css = text_style_css(style);
                if !css.is_empty() {
                    html = format!("<span style=\"{}\">{html}</span>", escape_attr(&css));
                }
            }
        }
    }
    if !rules.marks.contains_key("link") {
        if let Some(Any::Map(link)) = marks.get("link") {
            html = wrap_link(html, link);
        }
    }
    if !rules.marks.is_empty() {
        html = wrap_custom_marks(html, marks, rules);
    }
    html
}

/// Apply the run's registered custom marks, outermost of everything.
fn wrap_custom_marks(html: String, marks: &Attrs, rules: &Rules) -> String {
    let mut names: Vec<&str> = rules
        .marks
        .keys()
        .map(String::as_str)
        .filter(|name| marks.contains_key(*name))
        .collect();
    names.sort_unstable();
    let mut html = html;
    for name in names {
        html = wrap_custom_mark(html, &rules.marks[name], marks.get(name));
    }
    html
}

fn wrap_custom_mark(inner: String, rule: &MarkRule, value: Option<&Any>) -> String {
    let mut out = String::from("<");
    out.push_str(&rule.tag);
    for (attr, parts) in &rule.attrs {
        if let Some(v) = resolve_parts(parts, |r| mark_ref_attr(value, r)) {
            out.push(' ');
            out.push_str(attr);
            out.push_str("=\"");
            out.push_str(&escape_attr(&v));
            out.push('"');
        }
    }
    out.push('>');
    out.push_str(&inner);
    out.push_str("</");
    out.push_str(&rule.tag);
    out.push('>');
    out
}

/// An attribute reference on a custom mark: y-prosemirror stores mark attrs
/// as a map under the mark's name (bool `true` when the mark has none).
fn mark_ref_attr(value: Option<&Any>, name: &str) -> Option<String> {
    match value {
        Some(Any::Map(map)) => any_attr_string(map.get(name)?),
        _ => None,
    }
}

/// The `style` string for a textStyle mark (Tiptap's Color/FontFamily/etc.
/// extensions all store their value as a textStyle attribute). Attributes are
/// camelCase CSS property names; unset ones sit in the map as explicit nulls.
/// Keys sort alphabetically, which is the order Tiptap serializes (color
/// before font-family). Hex colors convert to rgb() because that's how they
/// come back out of the browser's style attribute; other values pass through.
fn text_style_css(style: &std::collections::HashMap<String, Any>) -> String {
    let mut pairs: Vec<_> = style
        .iter()
        .filter_map(|(k, v)| match v {
            Any::String(s) => Some((k, s.as_ref())),
            _ => None,
        })
        .collect();
    pairs.sort_by(|a, b| a.0.cmp(b.0));
    let mut css = String::new();
    for (key, value) in pairs {
        if !css.is_empty() {
            css.push(' ');
        }
        // camelCase -> kebab-case: fontFamily -> font-family.
        for ch in key.chars() {
            if ch.is_ascii_uppercase() {
                css.push('-');
                css.push(ch.to_ascii_lowercase());
            } else {
                css.push(ch);
            }
        }
        css.push_str(": ");
        css.push_str(&hex_to_rgb(value).unwrap_or_else(|| value.to_string()));
        css.push(';');
    }
    css
}

/// `#rgb`/`#rrggbb` -> `rgb(r, g, b)`, matching the browser's style-attribute
/// serialization. Anything else (named colors, rgb()/hsl(), fonts) is None.
fn hex_to_rgb(value: &str) -> Option<String> {
    let hex = value.strip_prefix('#')?;
    // len() and the slices below are byte-based; non-ASCII input would panic
    // on a char boundary. Real hex never is, crafted input passes through.
    if !hex.is_ascii() {
        return None;
    }
    let (r, g, b) = match hex.len() {
        3 => {
            let d = |i: usize| u8::from_str_radix(&hex[i..=i].repeat(2), 16);
            (d(0).ok()?, d(1).ok()?, d(2).ok()?)
        }
        6 => {
            let d = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16);
            (d(0).ok()?, d(2).ok()?, d(4).ok()?)
        }
        _ => return None,
    };
    Some(format!("rgb({r}, {g}, {b})"))
}

/// `<a>` with Tiptap's attribute order (target, rel, class, href, title),
/// skipping any that are absent or null.
fn wrap_link(inner: String, link: &std::collections::HashMap<String, Any>) -> String {
    let mut out = String::from("<a");
    for key in ["target", "rel", "class", "href", "title"] {
        if let Some(Any::String(v)) = link.get(key) {
            out.push(' ');
            out.push_str(key);
            out.push_str("=\"");
            out.push_str(&escape_attr(v));
            out.push('"');
        }
    }
    out.push('>');
    out.push_str(&inner);
    out.push_str("</a>");
    out
}

/// `<img>` with attribute order src, alt, title, skipping absent/null ones.
fn render_image<T: ReadTxn>(txn: &T, e: &XmlElementRef, em: &mut Emitter) {
    em.push_str("<img");
    for (attr, html) in [("src", "src"), ("alt", "alt"), ("title", "title")] {
        if let Some(v) = str_attr(txn, e, attr) {
            em.push(' ');
            em.push_str(html);
            em.push_str("=\"");
            em.push_str(&escape_attr(&v));
            em.push('"');
        }
    }
    em.push('>');
}

fn wrap(inner: String, tag: &str) -> String {
    format!("<{tag}>{inner}</{tag}>")
}

/// A mark is present and not claimed by a registered rule for that stored
/// name (a rule overrides the built-in wrap).
fn has(marks: &Attrs, keys: &[&str], rules: &Rules) -> bool {
    keys.iter()
        .any(|k| marks.contains_key(*k) && !rules.marks.contains_key(*k))
}

fn has_element_child<T: ReadTxn>(txn: &T, e: &XmlElementRef) -> bool {
    e.children(txn).any(|c| matches!(c, XmlOut::Element(_)))
}

/// The concatenated text of a code block (no marks — code is plain text).
fn code_text<T: ReadTxn>(txn: &T, e: &XmlElementRef) -> String {
    let mut s = String::new();
    for node in e.children(txn) {
        if let XmlOut::Text(t) = node {
            for d in t.diff(txn, YChange::identity) {
                if let Out::Any(Any::String(run)) = &d.insert {
                    s.push_str(run);
                }
            }
        }
    }
    s
}

fn str_attr<T: ReadTxn>(txn: &T, e: &XmlElementRef, name: &str) -> Option<String> {
    match e.get_attribute(txn, name) {
        Some(Out::Any(Any::String(s))) => Some(s.to_string()),
        _ => None,
    }
}

fn num_attr<T: ReadTxn>(txn: &T, e: &XmlElementRef, name: &str) -> Option<i64> {
    match e.get_attribute(txn, name) {
        Some(Out::Any(Any::Number(n))) => Some(n as i64),
        Some(Out::Any(Any::BigInt(n))) => Some(n),
        _ => None,
    }
}

fn bool_attr<T: ReadTxn>(txn: &T, e: &XmlElementRef, name: &str) -> bool {
    matches!(e.get_attribute(txn, name), Some(Out::Any(Any::Bool(true))))
}

/// Text-content escaping, matching the browser serializer: `&`, `<`, `>`.
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
    use std::collections::HashMap;
    use std::sync::Arc;
    use yrs::updates::decoder::Decode;
    use yrs::{Doc, Transact, Update, XmlElementPrelim, XmlTextPrelim};

    fn doc_from(bytes: &[u8]) -> Doc {
        let doc = Doc::new();
        doc.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
        doc
    }

    fn marks(keys: &[&str]) -> Attrs {
        let mut a = Attrs::new();
        for k in keys {
            a.insert((*k).into(), Any::Bool(true));
        }
        a
    }

    fn run(text: &str, marks: Option<&Attrs>) -> String {
        render_run(text, marks, &Rules::empty())
    }

    /// The core proof: a document captured from a real Tiptap editor renders to
    /// exactly the editor's own `getHTML()`. The fixture covers headings,
    /// every mark and combination, links, escaping, blockquote, nested bullet
    /// and ordered lists (with a `start`), a task list, code blocks with and
    /// without a language, a hard break, a horizontal rule, an image, and the
    /// trailing empty paragraph Tiptap keeps.
    #[test]
    fn renders_the_captured_tiptap_document_byte_for_byte() {
        let doc = doc_from(include_bytes!("fixtures/prosemirror_tiptap.bin"));
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("default").unwrap();
        assert_eq!(
            render(&txn, &frag).unwrap(),
            include_str!("fixtures/prosemirror_tiptap.html")
        );
    }

    /// A table renders as tiptap-php's semantic form — `<table><tbody>` with
    /// colspan/rowspan cells — dropping the `<colgroup>`/`min-width` styling
    /// Tiptap's editor view adds (and which isn't in the CRDT).
    #[test]
    fn renders_a_table_as_semantic_html() {
        let doc = doc_from(include_bytes!("fixtures/prosemirror_table.bin"));
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("default").unwrap();
        assert_eq!(
            render(&txn, &frag).unwrap(),
            include_str!("fixtures/prosemirror_table.html")
        );
    }

    #[test]
    fn marks_nest_in_tiptaps_serializer_order() {
        assert_eq!(run("x", None), "x");
        assert_eq!(run("x", Some(&marks(&["bold"]))), "<strong>x</strong>");
        assert_eq!(run("x", Some(&marks(&["italic"]))), "<em>x</em>");
        // bold wraps italic.
        assert_eq!(
            run("x", Some(&marks(&["italic", "bold"]))),
            "<strong><em>x</em></strong>"
        );
        // code excludes every other mark.
        assert_eq!(run("x", Some(&marks(&["code", "bold"]))), "<code>x</code>");
        // Full compatible stack, innermost sub to outermost bold.
        assert_eq!(
            run(
                "x",
                Some(&marks(&[
                    "bold",
                    "italic",
                    "strike",
                    "underline",
                    "highlight",
                    "subscript"
                ]))
            ),
            "<strong><em><s><u><mark><sub>x</sub></mark></u></s></em></strong>"
        );
        // Escaping happens before wrapping.
        assert_eq!(run("<&>", None), "&lt;&amp;&gt;");
    }

    #[test]
    fn renders_a_link_run_with_tiptaps_attribute_order() {
        let mut link = HashMap::new();
        link.insert(
            "href".to_string(),
            Any::String("https://e.com?a=1&b=2".into()),
        );
        link.insert("target".to_string(), Any::String("_blank".into()));
        link.insert("rel".to_string(), Any::String("noopener".into()));
        let mut a = Attrs::new();
        a.insert("link".into(), Any::Map(Arc::new(link)));
        assert_eq!(
            run("site", Some(&a)),
            "<a target=\"_blank\" rel=\"noopener\" href=\"https://e.com?a=1&amp;b=2\">site</a>"
        );

        // class and title (Link's remaining attrs) keep Tiptap's serialized
        // order: target, rel, class, href, title. Null-valued attrs skip.
        let mut link = HashMap::new();
        link.insert("href".to_string(), Any::String("https://d.example".into()));
        link.insert("class".to_string(), Any::String("doc-link".into()));
        link.insert("title".to_string(), Any::String("A Doc".into()));
        link.insert("target".to_string(), Any::Null);
        let mut a = Attrs::new();
        a.insert("link".into(), Any::Map(Arc::new(link)));
        assert_eq!(
            run("the doc", Some(&a)),
            "<a class=\"doc-link\" href=\"https://d.example\" title=\"A Doc\">the doc</a>"
        );
    }

    /// Mentions (captured from Tiptap's Mention extension): the fixture holds
    /// one mention with a label, one with only an id, and a link carrying
    /// class and title.
    #[test]
    fn renders_the_captured_mention_document_byte_for_byte() {
        let doc = doc_from(include_bytes!("fixtures/prosemirror_mention.bin"));
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("default").unwrap();
        assert_eq!(
            render(&txn, &frag).unwrap(),
            include_str!("fixtures/prosemirror_mention.html")
        );
    }

    /// textStyle (captured from Tiptap's Color/FontFamily extensions): hex
    /// colors come back out of the browser as rgb(), rgb() strings pass
    /// through, font-family joins the same span, and the span wraps outside
    /// bold.
    #[test]
    fn renders_the_captured_textstyle_document_byte_for_byte() {
        let doc = doc_from(include_bytes!("fixtures/prosemirror_textstyle.bin"));
        let txn = doc.transact();
        let frag = txn.get_xml_fragment("default").unwrap();
        assert_eq!(
            render(&txn, &frag).unwrap(),
            include_str!("fixtures/prosemirror_textstyle.html")
        );
    }

    #[test]
    fn text_style_converts_hex_and_kebab_cases_keys() {
        let mut style = HashMap::new();
        style.insert("color".to_string(), Any::String("#ff0000".into()));
        style.insert(
            "fontFamily".to_string(),
            Any::String("Georgia, serif".into()),
        );
        style.insert("fontSize".to_string(), Any::Null); // unset: skipped
        assert_eq!(
            text_style_css(&style),
            "color: rgb(255, 0, 0); font-family: Georgia, serif;"
        );

        assert_eq!(hex_to_rgb("#0f8"), Some("rgb(0, 255, 136)".to_string()));
        assert_eq!(hex_to_rgb("rebeccapurple"), None);
        assert_eq!(hex_to_rgb("#12345"), None);
        // Multibyte input must pass through, not panic on a byte-slice
        // boundary ("日" is one char, three bytes — it enters the 3 arm).
        assert_eq!(hex_to_rgb("#日"), None);
        assert_eq!(hex_to_rgb("#日本"), None);
    }

    /// A known container with bare text jammed directly into it (schema-valid
    /// documents never do this) keeps the text instead of dropping it.
    #[test]
    fn a_known_container_keeps_stray_direct_text() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("default");
        {
            let mut txn = doc.transact_mut();
            let bq = frag.push_back(&mut txn, XmlElementPrelim::empty("blockquote"));
            bq.push_back(&mut txn, XmlTextPrelim::new("stray"));
            let p = bq.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            p.push_back(&mut txn, XmlTextPrelim::new("body"));
        }
        let txn = doc.transact();
        assert_eq!(
            render(&txn, &frag).unwrap(),
            "<blockquote>stray<p>body</p></blockquote>"
        );
    }

    /// The details family follows tiptap-php's renderHTML (the Tiptap
    /// extension is Pro-only, so tiptap-php is the reference).
    #[test]
    fn renders_the_details_family_per_tiptap_php() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("default");
        {
            let mut txn = doc.transact_mut();
            let details = frag.push_back(&mut txn, XmlElementPrelim::empty("details"));
            details.insert_attribute(&mut txn, "open", true);
            let summary = details.push_back(&mut txn, XmlElementPrelim::empty("detailsSummary"));
            summary.push_back(&mut txn, XmlTextPrelim::new("More info"));
            let content = details.push_back(&mut txn, XmlElementPrelim::empty("detailsContent"));
            let p = content.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            p.push_back(&mut txn, XmlTextPrelim::new("The body."));

            let closed = frag.push_back(&mut txn, XmlElementPrelim::empty("details"));
            closed.push_back(&mut txn, XmlElementPrelim::empty("detailsSummary"));
        }
        let txn = doc.transact();
        assert_eq!(
            render(&txn, &frag).unwrap(),
            "<details open=\"open\"><summary>More info</summary>\
             <div data-type=\"detailsContent\"><p>The body.</p></div></details>\
             <details><summary></summary></details>"
        );
    }

    /// prosemirror-schema-basic's `code` mark has no excludes, so a code run
    /// can also carry a link; the link must survive. (Tiptap's Code mark
    /// excludes everything, so this shape only comes from schema-basic docs.)
    #[test]
    fn a_code_run_keeps_its_link() {
        let mut link = HashMap::new();
        link.insert("href".to_string(), Any::String("https://e.com".into()));
        let mut a = Attrs::new();
        a.insert("code".into(), Any::Map(Arc::new(HashMap::new())));
        a.insert("link".into(), Any::Map(Arc::new(link)));
        assert_eq!(
            run("x", Some(&a)),
            "<a href=\"https://e.com\"><code>x</code></a>"
        );
    }

    /// An unknown block holding both text and child blocks keeps the text.
    #[test]
    fn an_unknown_block_with_mixed_content_keeps_its_text() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("default");
        {
            let mut txn = doc.transact_mut();
            let callout = frag.push_back(&mut txn, XmlElementPrelim::empty("callout"));
            callout.push_back(&mut txn, XmlTextPrelim::new("intro"));
            let p = callout.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            p.push_back(&mut txn, XmlTextPrelim::new("body"));
        }
        let txn = doc.transact();
        assert_eq!(render(&txn, &frag).unwrap(), "intro<p>body</p>");
    }

    /// An unknown inline node keeps its text instead of vanishing.
    #[test]
    fn an_unknown_inline_node_keeps_its_text() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("default");
        {
            let mut txn = doc.transact_mut();
            let p = frag.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            p.push_back(&mut txn, XmlTextPrelim::new("see "));
            let custom = p.push_back(&mut txn, XmlElementPrelim::empty("customInline"));
            custom.push_back(&mut txn, XmlTextPrelim::new("kept"));
            p.push_back(&mut txn, XmlTextPrelim::new(" here"));
        }
        let txn = doc.transact();
        assert_eq!(render(&txn, &frag).unwrap(), "<p>see kept here</p>");
    }

    /// The prosemirror-schema-basic spellings (snake_case nodes, `strong`/`em`
    /// marks) render the same as Tiptap's camelCase.
    #[test]
    fn accepts_prosemirror_basic_schema_names() {
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("default");
        {
            let mut txn = doc.transact_mut();
            let bq = frag.push_back(&mut txn, XmlElementPrelim::empty("blockquote"));
            let p = bq.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            let t = p.push_back(&mut txn, XmlTextPrelim::new("hi bold it"));
            t.format(&mut txn, 3, 4, marks(&["strong"]));
            t.format(&mut txn, 8, 2, marks(&["em"]));
        }
        let txn = doc.transact();
        assert_eq!(
            render(&txn, &frag).unwrap(),
            "<blockquote><p>hi <strong>bold</strong> <em>it</em></p></blockquote>"
        );
    }

    #[test]
    fn a_lexical_shaped_root_is_refused() {
        // A Lexical doc stores blocks as XmlText carrying `__type`. That's a
        // different schema; render must return None, not a garbled document.
        let doc = Doc::new();
        // Create both roots before opening the read transaction:
        // get_or_insert_* opens its own write transaction, which would deadlock
        // against a live read guard.
        let frag = doc.get_or_insert_xml_fragment("root");
        let empty = doc.get_or_insert_xml_fragment("empty");
        {
            let mut txn = doc.transact_mut();
            let block = frag.push_back(&mut txn, XmlTextPrelim::new("hello"));
            block.insert_attribute(&mut txn, "__type", "paragraph");
        }
        let txn = doc.transact();
        assert_eq!(render(&txn, &frag), None);
        // An empty root is fine.
        assert_eq!(render(&txn, &empty).as_deref(), Some(""));
    }

    #[test]
    fn deeply_nested_blocks_do_not_overflow_the_stack() {
        // The walk is on the heap, so nesting that would blow a small native
        // stack under recursion renders fine. Built and rendered on a 512 KiB
        // thread so it can't pass just by having room to spare.
        std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(|| {
                let doc = Doc::new();
                let frag = doc.get_or_insert_xml_fragment("default");
                {
                    let mut txn = doc.transact_mut();
                    let mut cursor =
                        frag.push_back(&mut txn, XmlElementPrelim::empty("blockquote"));
                    for _ in 0..20_000 {
                        cursor = cursor.push_back(&mut txn, XmlElementPrelim::empty("blockquote"));
                    }
                    let p = cursor.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
                    p.push_back(&mut txn, XmlTextPrelim::new("deep"));
                }
                let txn = doc.transact();
                let html = render(&txn, &frag).expect("prosemirror-shaped");
                assert_eq!(
                    html.matches("<blockquote>").count(),
                    html.matches("</blockquote>").count()
                );
                assert!(html.contains("<p>deep</p>") || html.contains("<blockquote>"));
            })
            .unwrap()
            .join()
            .unwrap();
    }

    #[test]
    fn escaping_matches_the_browser_serializer() {
        assert_eq!(escape_text(r#"<a & "b">"#), r#"&lt;a &amp; "b"&gt;"#);
        assert_eq!(
            escape_attr(r#"<a & "b">"#),
            r#"&lt;a &amp; &quot;b&quot;&gt;"#
        );
    }

    /// A declarative node rule renders natively: tag, attribute refs resolved
    /// from the node's attrs, and a blocks content slot. Rules can also
    /// override a built-in (paragraph here).
    #[test]
    fn a_declarative_rule_renders_and_can_override_a_builtin() {
        let rules = Rules::parse(
            r#"{ "nodes": {
                 "callout": { "tag": "aside",
                              "attrs": [["class", [{"lit": "callout callout--"}, {"ref": "kind"}]]],
                              "content": "blocks" },
                 "paragraph": { "tag": "div", "attrs": [["class", [{"lit": "para"}]]] } } }"#,
        )
        .unwrap();
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("default");
        {
            let mut txn = doc.transact_mut();
            let callout = frag.push_back(&mut txn, XmlElementPrelim::empty("callout"));
            callout.insert_attribute(&mut txn, "kind", "warning");
            let p = callout.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            p.push_back(&mut txn, XmlTextPrelim::new("careful"));
        }
        let txn = doc.transact();
        let segs = render_segments(&txn, &frag, &rules).unwrap();
        assert_eq!(
            crate::render_rules::flatten(segs).unwrap(),
            "<aside class=\"callout callout--warning\"><div class=\"para\">careful</div></aside>"
        );
    }

    /// A callback rule defers: the node comes back as a Pending segment with
    /// its attrs as JSON and its children already rendered.
    #[test]
    fn a_callback_rule_emits_a_pending_segment_with_rendered_content() {
        let rules = Rules::parse(
            r#"{ "nodes": { "videoEmbed": { "callback": true, "content": "blocks" } } }"#,
        )
        .unwrap();
        let doc = Doc::new();
        let frag = doc.get_or_insert_xml_fragment("default");
        {
            let mut txn = doc.transact_mut();
            let intro = frag.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            intro.push_back(&mut txn, XmlTextPrelim::new("watch:"));
            let video = frag.push_back(&mut txn, XmlElementPrelim::empty("videoEmbed"));
            video.insert_attribute(&mut txn, "src", "https://v.example/1");
            let caption = video.push_back(&mut txn, XmlElementPrelim::empty("paragraph"));
            caption.push_back(&mut txn, XmlTextPrelim::new("the caption"));
        }
        let txn = doc.transact();
        let segs = render_segments(&txn, &frag, &rules).unwrap();
        assert_eq!(segs.len(), 2);
        assert!(matches!(&segs[0], Segment::Html(s) if s == "<p>watch:</p>"));
        let Segment::Pending {
            ty,
            attrs_json,
            content,
        } = &segs[1]
        else {
            panic!("expected a pending segment");
        };
        assert_eq!(ty, "videoEmbed");
        assert_eq!(attrs_json, r#"{"src":"https://v.example/1"}"#);
        assert!(matches!(&content[0], Segment::Html(s) if s == "<p>the caption</p>"));
    }

    /// A custom mark claims its stored name from the built-ins and wraps
    /// outside everything, attribute refs resolving against the mark's map.
    #[test]
    fn a_custom_mark_overrides_the_builtin_and_wraps_outermost() {
        let rules = Rules::parse(
            r#"{ "marks": {
                 "comment": { "tag": "span", "attrs": [["data-comment-id", [{"ref": "id"}]]] },
                 "bold": { "tag": "b" } } }"#,
        )
        .unwrap();
        let mut comment = HashMap::new();
        comment.insert("id".to_string(), Any::String("c1".into()));
        let mut a = Attrs::new();
        a.insert("bold".into(), Any::Bool(true));
        a.insert("italic".into(), Any::Bool(true));
        a.insert("comment".into(), Any::Map(Arc::new(comment)));
        assert_eq!(
            render_run("x", Some(&a), &rules),
            "<span data-comment-id=\"c1\"><b><em>x</em></b></span>"
        );
    }
}
