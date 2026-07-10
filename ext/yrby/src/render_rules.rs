//! Custom render rules and segmented output — the extensibility core shared
//! by both HTML renderers.
//!
//! Apps register per-node rules from Ruby. Two tiers:
//!
//! - **Declarative rules** (tag, attributes, text, content slot) compile to
//!   [`NodeRule`]/[`MarkRule`] here and render natively, inside `nogvl`, at
//!   full speed. This covers the tiptap-php `renderHTML` shape: markup as
//!   data.
//! - **Callback rules** defer to Ruby. Rendering never calls Ruby while the
//!   document is locked — instead the renderer emits [`Segment::Deferred`]
//!   entries carrying the node's type, attributes (as JSON), and its
//!   already-rendered children; the Ruby layer invokes the app's block after
//!   the transaction has closed and the GVL is held again, then splices.
//!
//! Rules cross the Ruby boundary as one JSON document (see `parse`), so the
//! same format serves any future binding.

use std::collections::HashMap;
use yrs::{Any, Out, ReadTxn, Xml};

/// One piece of renderer output. `Html` is finished markup; `Deferred` is a
/// callback node whose markup the caller supplies after the render, carrying
/// everything needed to produce it. Content nests, so callback nodes inside
/// callback nodes resolve depth-first. `child_types` lists the node's
/// element/block children by type, in document order — structural facts a
/// callback can't recover from `attrs` or the rendered content (an image
/// count, whether a list item holds a nested list).
#[derive(Debug)]
pub enum Segment {
    Html(String),
    Deferred {
        node_type: String,
        attrs_json: String,
        child_types: Vec<String>,
        content: Vec<Segment>,
    },
}

/// Builds segmented output. Renderers append markup through this instead of a
/// bare `String`; frames capture sub-output (a deferred node's children, or a
/// "did this render anything?" probe) without string sentinels.
pub struct Emitter {
    frames: Vec<Vec<Segment>>,
}

impl Emitter {
    pub fn new() -> Self {
        Emitter {
            frames: vec![Vec::new()],
        }
    }

    pub fn push_str(&mut self, s: &str) {
        if s.is_empty() {
            return;
        }
        let frame = self.frames.last_mut().expect("emitter frame");
        if let Some(Segment::Html(last)) = frame.last_mut() {
            last.push_str(s);
        } else {
            frame.push(Segment::Html(s.to_string()));
        }
    }

    pub fn push(&mut self, c: char) {
        let mut buf = [0u8; 4];
        self.push_str(c.encode_utf8(&mut buf));
    }

    /// Start capturing output into a sub-frame.
    pub fn begin_frame(&mut self) {
        self.frames.push(Vec::new());
    }

    /// Finish the current sub-frame and return what it captured.
    pub fn end_frame(&mut self) -> Vec<Segment> {
        debug_assert!(self.frames.len() > 1, "unbalanced emitter frame");
        self.frames.pop().unwrap_or_default()
    }

    /// Append previously captured segments to the current frame.
    pub fn append(&mut self, segments: Vec<Segment>) {
        for seg in segments {
            match seg {
                Segment::Html(s) => self.push_str(&s),
                deferred => self
                    .frames
                    .last_mut()
                    .expect("emitter frame")
                    .push(deferred),
            }
        }
    }

    pub fn emit_deferred(
        &mut self,
        node_type: String,
        attrs_json: String,
        child_types: Vec<String>,
        content: Vec<Segment>,
    ) {
        self.frames
            .last_mut()
            .expect("emitter frame")
            .push(Segment::Deferred {
                node_type,
                attrs_json,
                child_types,
                content,
            });
    }

    pub fn into_segments(mut self) -> Vec<Segment> {
        debug_assert_eq!(self.frames.len(), 1, "unbalanced emitter frame");
        self.frames.pop().unwrap_or_default()
    }
}

/// What flattening produced. Both variants are normal outcomes — `Deferred`
/// isn't a failure, it's "callback nodes are present, splice them" — so this
/// is an enum, not a `Result`.
pub enum Flattened {
    Html(String),
    Deferred(Vec<Segment>),
}

impl Flattened {
    /// The finished markup, or `None` when callback nodes still need
    /// splicing. Handy where the caller knows no callback rules exist.
    /// (Only test code needs it today, but it's part of the shape the
    /// extracted crates will expose.)
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn into_html(self) -> Option<String> {
        match self {
            Flattened::Html(html) => Some(html),
            Flattened::Deferred(_) => None,
        }
    }
}

/// Join the segments when every one is finished markup, so the common
/// no-callback path stays a single string and the splicing layer can be
/// skipped; hand the segments back untouched when callback nodes are present.
pub fn flatten(segments: Vec<Segment>) -> Flattened {
    if segments
        .iter()
        .any(|s| matches!(s, Segment::Deferred { .. }))
    {
        return Flattened::Deferred(segments);
    }
    // The merge invariant makes the common case exactly one Html segment;
    // move it out rather than copying the whole document.
    let mut out = String::new();
    for seg in segments {
        if let Segment::Html(s) = seg {
            if out.is_empty() {
                out = s;
            } else {
                out.push_str(&s);
            }
        }
    }
    Flattened::Html(out)
}

/// A piece of an attribute value or text template: a literal, or a reference
/// to one of the node's stored attributes.
pub enum AttrPart {
    Lit(String),
    Ref(String),
}

/// Resolve a lit/ref template against a node's attributes. `None` (attribute
/// or text skipped) when the resolved value is empty — matching how the
/// built-in renderers omit absent attributes.
pub fn resolve_parts<F: Fn(&str) -> Option<String>>(
    parts: &[AttrPart],
    lookup: F,
) -> Option<String> {
    let mut out = String::new();
    for part in parts {
        match part {
            AttrPart::Lit(s) => out.push_str(s),
            AttrPart::Ref(name) => {
                if let Some(v) = lookup(name) {
                    out.push_str(&v);
                }
            }
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// An attribute reference on a node: rules say `:kind`; Lexical stores its own
/// props as `__kind` — try the raw name first, then prefixed. (ProseMirror
/// stores attrs bare, so the fallback never fires there.)
pub fn xml_ref_attr<T: ReadTxn, N: Xml>(txn: &T, node: &N, name: &str) -> Option<String> {
    let value = |out: Option<Out>| match out {
        Some(Out::Any(any)) => any_attr_string(&any),
        _ => None,
    };
    value(node.get_attribute(txn, name))
        .or_else(|| value(node.get_attribute(txn, &format!("__{name}"))))
}

/// A stored attribute as a string: strings pass through; numbers print
/// JS-style; bools as true/false. Anything else is None.
pub fn any_attr_string(any: &Any) -> Option<String> {
    match any {
        Any::String(s) => Some(s.to_string()),
        Any::Number(n) => Some(if n.fract() == 0.0 {
            format!("{}", *n as i64)
        } else {
            format!("{n}")
        }),
        Any::BigInt(n) => Some(format!("{n}")),
        Any::Bool(b) => Some(if *b { "true" } else { "false" }.to_string()),
        _ => None,
    }
}

/// A node's stored attributes as a JSON object, for callback rules. Keys as
/// stored (`__type` and friends keep their prefix); values via yrs's own JSON
/// encoding.
pub fn xml_attrs_json<T: ReadTxn, N: Xml>(txn: &T, node: &N) -> String {
    let mut out = String::from("{");
    let mut first = true;
    for (key, value) in node.attributes(txn) {
        let Out::Any(any) = value else { continue };
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(&serde_json::to_string(key).unwrap_or_else(|_| "\"\"".into()));
        out.push(':');
        let mut v = String::new();
        any.to_json(&mut v);
        out.push_str(&v);
    }
    out.push('}');
    out
}

/// What goes inside a custom node's element.
#[derive(Clone, Copy, PartialEq)]
pub enum Content {
    Blocks,
    Inline,
    None,
}

pub struct NodeRule {
    /// None for callback rules (Ruby supplies the markup).
    pub tag: Option<String>,
    pub void: bool,
    pub attrs: Vec<(String, Vec<AttrPart>)>,
    pub text: Option<Vec<AttrPart>>,
    pub content: Content,
    pub callback: bool,
}

/// A custom mark (ProseMirror only): a wrapping tag with attributes read from
/// the mark's own value map.
pub struct MarkRule {
    pub tag: String,
    pub attrs: Vec<(String, Vec<AttrPart>)>,
}

pub struct Rules {
    pub nodes: HashMap<String, NodeRule>,
    pub marks: HashMap<String, MarkRule>,
    pub has_callbacks: bool,
}

impl Rules {
    pub fn empty() -> Self {
        Rules {
            nodes: HashMap::new(),
            marks: HashMap::new(),
            has_callbacks: false,
        }
    }

    /// Parse the JSON the Ruby layer compiles. Shape:
    ///
    /// ```json
    /// { "nodes": { "callout": { "tag": "aside", "void": false,
    ///                           "attrs": [["class", [{"lit": "callout"}]],
    ///                                     ["data-kind", [{"ref": "kind"}]]],
    ///                           "text": null, "content": "blocks",
    ///                           "callback": false } },
    ///   "marks": { "comment": { "tag": "span",
    ///                           "attrs": [["data-id", [{"ref": "id"}]]] } } }
    /// ```
    pub fn parse(json: &str) -> Result<Rules, String> {
        let root: serde_json::Value =
            serde_json::from_str(json).map_err(|e| format!("invalid rules JSON: {e}"))?;
        let mut rules = Rules::empty();

        if let Some(nodes) = root.get("nodes").and_then(|v| v.as_object()) {
            for (name, spec) in nodes {
                let rule = parse_node_rule(name, spec)?;
                rules.has_callbacks |= rule.callback;
                rules.nodes.insert(name.clone(), rule);
            }
        }
        if let Some(marks) = root.get("marks").and_then(|v| v.as_object()) {
            for (name, spec) in marks {
                rules
                    .marks
                    .insert(name.clone(), parse_mark_rule(name, spec)?);
            }
        }
        Ok(rules)
    }
}

fn parse_node_rule(name: &str, spec: &serde_json::Value) -> Result<NodeRule, String> {
    let callback = spec
        .get("callback")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let tag = spec.get("tag").and_then(|v| v.as_str()).map(String::from);
    if !callback && tag.is_none() {
        return Err(format!("rule for {name:?} needs a tag (or a callback)"));
    }
    Ok(NodeRule {
        tag,
        void: spec.get("void").and_then(|v| v.as_bool()).unwrap_or(false),
        attrs: parse_attrs(name, spec.get("attrs"))?,
        text: match spec.get("text") {
            Some(serde_json::Value::Array(parts)) => Some(parse_parts(name, parts)?),
            Some(serde_json::Value::Null) | None => None,
            Some(_) => return Err(format!("rule for {name:?}: text must be a template array")),
        },
        content: match spec.get("content").and_then(|v| v.as_str()) {
            Some("blocks") => Content::Blocks,
            Some("inline") | None => Content::Inline,
            Some("none") => Content::None,
            Some(other) => {
                return Err(format!(
                    "rule for {name:?}: unknown content kind {other:?} (blocks|inline|none)"
                ))
            }
        },
        callback,
    })
}

fn parse_mark_rule(name: &str, spec: &serde_json::Value) -> Result<MarkRule, String> {
    let Some(tag) = spec.get("tag").and_then(|v| v.as_str()) else {
        return Err(format!("mark rule for {name:?} needs a tag"));
    };
    Ok(MarkRule {
        tag: tag.to_string(),
        attrs: parse_attrs(name, spec.get("attrs"))?,
    })
}

fn parse_attrs(
    name: &str,
    attrs: Option<&serde_json::Value>,
) -> Result<Vec<(String, Vec<AttrPart>)>, String> {
    let mut out = Vec::new();
    let Some(serde_json::Value::Array(entries)) = attrs else {
        return Ok(out);
    };
    for entry in entries {
        let (Some(attr_name), Some(serde_json::Value::Array(parts))) =
            (entry.get(0).and_then(|v| v.as_str()), entry.get(1))
        else {
            return Err(format!("rule for {name:?}: malformed attrs entry"));
        };
        out.push((attr_name.to_string(), parse_parts(name, parts)?));
    }
    Ok(out)
}

fn parse_parts(name: &str, parts: &[serde_json::Value]) -> Result<Vec<AttrPart>, String> {
    parts
        .iter()
        .map(|part| {
            if let Some(lit) = part.get("lit").and_then(|v| v.as_str()) {
                Ok(AttrPart::Lit(lit.to_string()))
            } else if let Some(r) = part.get("ref").and_then(|v| v.as_str()) {
                Ok(AttrPart::Ref(r.to_string()))
            } else {
                Err(format!(
                    "rule for {name:?}: template part must be lit or ref"
                ))
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_compiled_rule_shape() {
        let rules = Rules::parse(
            r#"{ "nodes": { "callout": { "tag": "aside",
                                         "attrs": [["class", [{"lit": "callout"}]],
                                                   ["data-kind", [{"ref": "kind"}]]],
                                         "content": "blocks" },
                            "video": { "callback": true } },
                 "marks": { "comment": { "tag": "span",
                                         "attrs": [["data-id", [{"ref": "id"}]]] } } }"#,
        )
        .unwrap();
        assert_eq!(rules.nodes.len(), 2);
        assert!(rules.has_callbacks);
        let callout = &rules.nodes["callout"];
        assert_eq!(callout.tag.as_deref(), Some("aside"));
        assert!(matches!(callout.content, Content::Blocks));
        assert_eq!(callout.attrs.len(), 2);
        assert!(rules.nodes["video"].callback);
        assert_eq!(rules.marks["comment"].tag, "span");
    }

    #[test]
    fn rejects_malformed_rules_loudly() {
        assert!(Rules::parse("not json").is_err());
        assert!(Rules::parse(r#"{ "nodes": { "x": {} } }"#).is_err()); // no tag, no callback
        assert!(Rules::parse(r#"{ "nodes": { "x": { "tag": "a", "content": "wat" } } }"#).is_err());
        assert!(Rules::parse(r#"{ "marks": { "x": {} } }"#).is_err());
    }

    #[test]
    fn emitter_frames_capture_and_merge() {
        let mut em = Emitter::new();
        em.push_str("<p>");
        em.begin_frame();
        em.push_str("inner");
        let captured = em.end_frame();
        em.emit_deferred("video".into(), "{}".into(), Vec::new(), captured);
        em.push_str("</p>");
        let segs = em.into_segments();
        assert_eq!(segs.len(), 3);
        assert!(matches!(&segs[0], Segment::Html(s) if s == "<p>"));
        assert!(matches!(&segs[1], Segment::Deferred { node_type, .. } if node_type == "video"));
        assert!(matches!(&segs[2], Segment::Html(s) if s == "</p>"));

        // Adjacent Html merges; flatten() hands deferred segments back.
        let mut em = Emitter::new();
        em.push_str("a");
        em.push_str("b");
        let segs = em.into_segments();
        assert_eq!(segs.len(), 1);
        assert_eq!(flatten(segs).into_html().unwrap(), "ab");
    }
}
