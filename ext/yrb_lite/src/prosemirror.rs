//! Extract ProseMirror content from Y.Doc state without JavaScript.
//!
//! Ported from the original standalone CLI sketch (tools/extract_prosemirror.rs
//! in the archived FFI repo) into the native extension so extraction happens
//! in-process — no subprocess, no temp files.
//!
//! See docs/PROSEMIRROR.md and docs/ACCURACY.md for the research behind the
//! ProseMirror <-> Y.Doc mapping.

use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::Arc;
use yrs::types::text::YChange;
use yrs::updates::decoder::Decode;
use yrs::{
    Any, Doc, Out, ReadTxn, Text, Transact, Update, Xml, XmlElementRef, XmlFragment, XmlOut,
    XmlTextRef,
};

/// Fragment names tried (in order) when none is given explicitly.
/// "prosemirror" is y-prosemirror's default; "default"/"doc" are common alternatives.
const DEFAULT_FRAGMENTS: [&str; 3] = ["prosemirror", "default", "doc"];

/// Decode a V1 update into a fresh Doc and extract ProseMirror JSON from it.
pub fn extract_from_update(update: &[u8], fragment: Option<&str>) -> Result<Value, String> {
    let doc = Doc::new();
    {
        let update =
            Update::decode_v1(update).map_err(|e| format!("Failed to decode update: {}", e))?;
        let mut txn = doc.transact_mut();
        txn.apply_update(update)
            .map_err(|e| format!("Failed to apply update: {}", e))?;
    }
    let txn = doc.transact();
    extract_from_txn(&txn, fragment)
}

/// Extract ProseMirror JSON from an existing transaction.
pub fn extract_from_txn<T: ReadTxn>(txn: &T, fragment: Option<&str>) -> Result<Value, String> {
    let root = match fragment {
        Some(name) => txn
            .get_xml_fragment(name)
            .ok_or_else(|| format!("No XML fragment named {:?} found", name))?,
        None => DEFAULT_FRAGMENTS
            .iter()
            .find_map(|name| txn.get_xml_fragment(*name))
            .ok_or_else(|| {
                format!(
                    "No ProseMirror content found (tried fragments: {:?})",
                    DEFAULT_FRAGMENTS
                )
            })?,
    };

    Ok(json!({
        "type": "doc",
        "content": children_to_json(&root, txn),
    }))
}

/// Convert the children of any XML container (fragment or element) to
/// ProseMirror node JSON.
fn children_to_json<F: XmlFragment, T: ReadTxn>(node: &F, txn: &T) -> Vec<Value> {
    let mut content = Vec::new();
    for child in node.children(txn) {
        match child {
            XmlOut::Element(elem) => content.push(element_to_json(&elem, txn)),
            XmlOut::Text(text) => content.extend(text_to_json(&text, txn)),
            _ => {}
        }
    }
    content
}

fn element_to_json<T: ReadTxn>(elem: &XmlElementRef, txn: &T) -> Value {
    let mut node = Map::new();
    node.insert("type".to_string(), json!(elem.tag()));

    let attrs: Vec<_> = elem.attributes(txn).collect();
    if !attrs.is_empty() {
        let mut attrs_map = Map::new();
        for (key, value) in attrs {
            attrs_map.insert(key.to_string(), json!(value));
        }
        node.insert("attrs".to_string(), Value::Object(attrs_map));
    }

    let children = children_to_json(elem, txn);
    if !children.is_empty() {
        node.insert("content".to_string(), Value::Array(children));
    }

    Value::Object(node)
}

/// Extract text runs with formatting marks (bold, italic, links, ...).
fn text_to_json<T: ReadTxn>(text: &XmlTextRef, txn: &T) -> Vec<Value> {
    let mut result = Vec::new();

    for delta in text.diff(txn, YChange::identity) {
        let text_str = match delta.insert {
            Out::Any(Any::String(s)) => s,
            _ => continue,
        };
        if text_str.is_empty() {
            continue;
        }

        let mut node = Map::new();
        node.insert("type".to_string(), json!("text"));
        node.insert("text".to_string(), json!(text_str.as_ref()));

        if let Some(attrs) = delta.attributes {
            let marks = attrs_to_marks(&attrs);
            if !marks.is_empty() {
                node.insert("marks".to_string(), Value::Array(marks));
            }
        }

        result.push(Value::Object(node));
    }

    result
}

/// Map text formatting attributes to ProseMirror marks.
/// Keys are sorted for deterministic output (Attrs is a HashMap).
fn attrs_to_marks(attrs: &HashMap<Arc<str>, Any>) -> Vec<Value> {
    let mut keys: Vec<_> = attrs.keys().collect();
    keys.sort();

    let mut marks = Vec::new();
    for key in keys {
        let value = &attrs[key];
        match key.as_ref() {
            "bold" | "strong" => {
                if is_truthy(value) {
                    marks.push(json!({"type": "bold"}));
                }
            }
            "italic" | "em" => {
                if is_truthy(value) {
                    marks.push(json!({"type": "italic"}));
                }
            }
            "code" => {
                if is_truthy(value) {
                    marks.push(json!({"type": "code"}));
                }
            }
            "underline" => {
                if is_truthy(value) {
                    marks.push(json!({"type": "underline"}));
                }
            }
            "strike" | "strikethrough" => {
                if is_truthy(value) {
                    marks.push(json!({"type": "strike"}));
                }
            }
            "link" => {
                // Link mark with href attribute. Tiptap may store either a
                // plain href string or a map of attrs.
                match value {
                    Any::String(href) => marks.push(json!({
                        "type": "link",
                        "attrs": {"href": href.as_ref()}
                    })),
                    _ => marks.push(json!({
                        "type": "link",
                        "attrs": any_to_json(value)
                    })),
                }
            }
            _ => {
                // Generic mark with attributes
                marks.push(json!({
                    "type": key.as_ref(),
                    "attrs": any_to_json(value)
                }));
            }
        }
    }

    marks
}

fn is_truthy(value: &Any) -> bool {
    match value {
        Any::Bool(b) => *b,
        Any::Number(n) => *n != 0.0,
        Any::BigInt(i) => *i != 0,
        Any::String(s) => !s.is_empty() && s.as_ref() != "false",
        _ => false,
    }
}

fn any_to_json(value: &Any) -> Value {
    match value {
        Any::Null | Any::Undefined => Value::Null,
        Any::Bool(b) => json!(b),
        Any::Number(n) => json!(n),
        Any::BigInt(i) => json!(i),
        Any::String(s) => json!(s.as_ref()),
        Any::Buffer(buf) => json!(buf.iter().map(|b| *b as u64).collect::<Vec<_>>()),
        Any::Array(items) => Value::Array(items.iter().map(any_to_json).collect()),
        Any::Map(map) => {
            let mut keys: Vec<_> = map.keys().collect();
            keys.sort();
            Value::Object(
                keys.into_iter()
                    .map(|k| (k.clone(), any_to_json(&map[k])))
                    .collect(),
            )
        }
    }
}
