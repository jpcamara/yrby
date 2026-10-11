//! Live `Y::XmlText` handles: write rich text from Ruby.
//!
//! Rich-text editors built on Yjs (Lexical among them) keep their document in
//! `XmlText` nodes: a root, blocks embedded in it, and inside a block a run of
//! embeds and strings. This handle exposes exactly the operations that shape
//! needs: read the text, set attributes, insert strings, insert embeds, and
//! add a nested `XmlText` block and get a handle to it.
//!
//! Same contract as the other handles: a transaction per operation inside
//! `nogvl`, the branch resolved from its identity each time, Ruby touched only
//! with the GVL held. A handle to a block stays on that block while people
//! add and remove blocks around it; indexes inside a block are Ruby
//! characters, with each embed counting as one.

use magnus::{prelude::*, Error, RHash, Ruby, Value};
use yrs::branch::BranchID;
use yrs::{
    Any, Assoc, Doc, GetString, IndexedSequence, Out, StickyIndex, Text, Transact, Xml,
    XmlTextPrelim, XmlTextRef,
};

use crate::nogvl;
use crate::shared::{
    any_to_ruby, block_text, char_len, delete_span, element_index, embedded_xml_text_index,
    embedded_xml_texts, ends_with_xml_text, guarded, hash_pairs, identity, insert_index, resolve,
    ruby_to_invalue, to_in, to_map_prelim, to_units, InValue, Position, ORIGIN,
};
use crate::yrb_error;

#[magnus::wrap(class = "Y::XmlText", free_immediately, size)]
pub struct RbXmlText {
    doc: Doc,
    id: BranchID,
    /// The root this block lives under, which an anchor carries.
    root: String,
}

impl RbXmlText {
    pub fn new(doc: Doc, id: BranchID, root: String) -> Self {
        RbXmlText { doc, id, root }
    }

    fn child(&self, block: &XmlTextRef) -> Self {
        RbXmlText::new(self.doc.clone(), identity(block), self.root.clone())
    }

    // --- reads ---

    fn to_s(&self) -> String {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<XmlTextRef, _>(&txn, id)
                .map(|x| x.get_string(&txn))
                .unwrap_or_default()
        })
    }

    /// The text of this block: its strings, without the node markers, with
    /// nested blocks (a list's items) joined by newlines. What a process reads
    /// when it wants to know what a block says.
    fn text(&self) -> String {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<XmlTextRef, _>(&txn, id)
                .map(|x| block_text(&txn, &x))
                .unwrap_or_default()
        })
    }

    /// The length in characters, each embed counting as one.
    fn length(&self) -> usize {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<XmlTextRef, _>(&txn, id)
                .map(|x| char_len(&txn, &x) as usize)
                .unwrap_or(0)
        })
    }

    fn is_empty(&self) -> bool {
        self.length() == 0
    }

    /// The name of the root this block lives under; an anchor carries it.
    fn root_name(&self) -> String {
        self.root.clone()
    }

    /// This block's attributes (`__type`, `__tag`, ...), as a Hash. What a
    /// process keeps to put a block back the way it was.
    fn attributes(&self) -> Result<RHash, Error> {
        let (doc, id) = (&self.doc, &self.id);
        let pairs: Vec<(String, Any)> = nogvl(move || {
            let txn = doc.transact();
            match resolve::<XmlTextRef, _>(&txn, id) {
                Some(x) => x
                    .attributes(&txn)
                    .map(|(key, value)| {
                        let any = match value {
                            Out::Any(a) => a,
                            other => Any::from(other.to_string(&txn)),
                        };
                        (key.to_string(), any)
                    })
                    .collect(),
                None => Vec::new(),
            }
        });
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let hash = ruby.hash_new();
        for (key, any) in pairs {
            hash.aset(key, any_to_ruby(&ruby, &any))?;
        }
        Ok(hash)
    }

    /// How many `XmlText` blocks this one embeds.
    fn xml_text_count(&self) -> usize {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<XmlTextRef, _>(&txn, id)
                .map(|x| embedded_xml_texts(&txn, &x).len())
                .unwrap_or(0)
        })
    }

    /// A live handle to the `n`-th embedded `XmlText` block, or nil when there
    /// is none. A negative `n` counts from the last. The handle stays on that
    /// block, wherever it moves.
    fn xml_text(&self, n: i64) -> Option<Self> {
        let (doc, id) = (&self.doc, &self.id);
        let block = nogvl(move || {
            let txn = doc.transact();
            let blocks = embedded_xml_texts(&txn, &resolve::<XmlTextRef, _>(&txn, id)?);
            let n = element_index(n, blocks.len() as u32)?;
            Some(identity(&blocks[n as usize]))
        })?;
        Some(RbXmlText::new(self.doc.clone(), block, self.root.clone()))
    }

    /// Whether the last thing in this block is an embedded block (a link).
    /// Text appended there needs a text node of its own.
    fn ends_with_xml_text(&self) -> bool {
        let (doc, id) = (&self.doc, &self.id);
        nogvl(move || {
            let txn = doc.transact();
            resolve::<XmlTextRef, _>(&txn, id)
                .map(|x| ends_with_xml_text(&txn, &x))
                .unwrap_or(false)
        })
    }

    // --- writes ---

    /// Set one attribute (a string, number, or nil).
    fn set_attribute(&self, key: String, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            x.insert_attribute(&mut txn, key, to_in(iv));
            Ok(())
        })?;
        Ok(value)
    }

    /// Insert a string at character `index`, as `String#insert` does: a
    /// negative index counts from the end (-1 appends). Clamped into range.
    fn insert(&self, index: i64, chunk: String) -> Result<String, Error> {
        let (doc, id) = (&self.doc, &self.id);
        let text = chunk.clone();
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            let at = to_units(&txn, &x, insert_index(index, char_len(&txn, &x)));
            x.insert(&mut txn, at, &text);
            Ok(())
        })?;
        Ok(chunk)
    }

    /// Insert an embed at `index`. A Hash becomes a nested shared map, which
    /// is what an editor's node marker is (Lexical keeps a text node's
    /// properties in a `Y.Map` embedded before its characters). A scalar is
    /// embedded as a plain value.
    fn insert_embed(&self, index: i64, value: Value) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let iv = ruby_to_invalue(&ruby, value)?;
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            let at = to_units(&txn, &x, insert_index(index, char_len(&txn, &x)));
            match iv {
                InValue::Map(entries) => {
                    x.insert_embed(&mut txn, at, to_map_prelim(entries));
                }
                InValue::Any(a) => {
                    x.insert_embed(&mut txn, at, a);
                }
            }
            Ok(())
        })?;
        Ok(value)
    }

    /// The Yjs relative position of character `index` as the `{type, tname,
    /// item, assoc}` hash editors put in awareness as a caret. `assoc` is
    /// "after" (the default: the space before the item at `index`) or
    /// "before".
    fn native_relative_position(&self, index: i64, assoc: String) -> Result<RHash, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let assoc = if assoc == "before" {
            Assoc::Before
        } else {
            Assoc::After
        };
        let (doc, id) = (&self.doc, &self.id);
        let position = guarded(move || {
            let txn = doc.transact();
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            let at = to_units(&txn, &x, insert_index(index, char_len(&txn, &x)));
            // Past the last item there is nothing to name, so Yjs anchors the
            // position to the type itself (the block, or the root). Same here.
            let sticky = x
                .sticky_index(&txn, at, assoc)
                .unwrap_or_else(|| StickyIndex::from_type(&txn, &x, assoc));
            Ok(Position::new(sticky))
        })?;
        position.to_ruby(&ruby)
    }

    /// The position that names this block itself: an anchor's position. It
    /// resolves to this block for as long as the block exists, whatever
    /// happens to the text inside it.
    fn native_block_position(&self) -> Result<RHash, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let (doc, id) = (&self.doc, &self.id);
        let position = guarded(move || {
            let txn = doc.transact();
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            Ok(Position::new(StickyIndex::from_type(
                &txn,
                &x,
                Assoc::After,
            )))
        })?;
        position.to_ruby(&ruby)
    }

    /// Remove `length` characters from `index`, as `String#slice!` does: a
    /// negative index counts from the end, and the length stops at the end.
    fn delete(&self, index: i64, length: i64) -> Result<(), Error> {
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            if let Some((from, to)) = delete_span(index, length, char_len(&txn, &x)) {
                let (from, to) = (to_units(&txn, &x, from), to_units(&txn, &x, to));
                if to > from {
                    x.remove_range(&mut txn, from, to - from);
                }
            }
            Ok(())
        })
    }

    /// Remove everything: markers, text, and embedded blocks.
    fn clear(&self) -> Result<(), Error> {
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            let len = x.len(&txn);
            if len > 0 {
                x.remove_range(&mut txn, 0, len);
            }
            Ok(())
        })
    }

    /// Insert a nested `XmlText` block with `attributes` before the `n`-th
    /// embedded block and return a live handle to it. A negative `n` counts
    /// from the end, so -1 adds it after the last; past the end it goes last.
    fn insert_xml_text(&self, n: i64, attributes: RHash) -> Result<Self, Error> {
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let pairs = hash_pairs(&ruby, attributes)?;
        let (doc, id) = (&self.doc, &self.id);
        let block = guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            let count = embedded_xml_texts(&txn, &x).len() as u32;
            let ordinal = insert_index(n, count);
            let at = embedded_xml_text_index(&txn, &x, ordinal).unwrap_or_else(|| x.len(&txn));
            let child = x.insert_embed(&mut txn, at, XmlTextPrelim::new(""));
            for (k, v) in pairs {
                child.insert_attribute(&mut txn, k, to_in(v));
            }
            Ok(child)
        })?;
        Ok(self.child(&block))
    }

    /// Remove the `n`-th embedded block (a negative `n` counts from the
    /// last). Returns whether there was one.
    fn delete_xml_text(&self, n: i64) -> Result<bool, Error> {
        let (doc, id) = (&self.doc, &self.id);
        guarded(move || {
            let mut txn = doc.transact_mut_with(ORIGIN);
            let x = resolve::<XmlTextRef, _>(&txn, id).ok_or("the block no longer exists")?;
            let count = embedded_xml_texts(&txn, &x).len() as u32;
            let Some(at) =
                element_index(n, count).and_then(|n| embedded_xml_text_index(&txn, &x, n))
            else {
                return Ok(false);
            };
            x.remove_range(&mut txn, at, 1);
            Ok(true)
        })
    }

    /// Append a nested `XmlText` block with `attributes` and return a live
    /// handle to it. This is how a paragraph is added to a Lexical document.
    fn push_xml_text(&self, attributes: RHash) -> Result<Self, Error> {
        self.insert_xml_text(-1, attributes)
    }
}

/// Ensure a root xml text exists and return a live handle. Called by
/// `Y::Doc#get_xml_text`.
pub fn root_xml_text(doc: &Doc, name: String) -> RbXmlText {
    let d = doc.clone();
    let root = name.clone();
    nogvl(move || {
        d.get_or_insert_xml_fragment(root.as_str());
    });
    RbXmlText::new(doc.clone(), BranchID::Root(name.as_str().into()), name)
}

/// A handle to the block `id` names, under `root`. How `Doc#find` hands one
/// back.
pub fn handle(doc: &Doc, id: BranchID, root: String) -> RbXmlText {
    RbXmlText::new(doc.clone(), id, root)
}

pub fn define(ruby: &Ruby, module: magnus::RModule) -> Result<(), Error> {
    let class = module.define_class("XmlText", ruby.class_object())?;
    class.define_method("to_s", magnus::method!(RbXmlText::to_s, 0))?;
    class.define_method("to_str", magnus::method!(RbXmlText::to_s, 0))?;
    class.define_method("text", magnus::method!(RbXmlText::text, 0))?;
    class.define_method("length", magnus::method!(RbXmlText::length, 0))?;
    class.define_method("size", magnus::method!(RbXmlText::length, 0))?;
    class.define_method("empty?", magnus::method!(RbXmlText::is_empty, 0))?;
    class.define_method("root_name", magnus::method!(RbXmlText::root_name, 0))?;
    class.define_method("attributes", magnus::method!(RbXmlText::attributes, 0))?;
    class.define_method(
        "xml_text_count",
        magnus::method!(RbXmlText::xml_text_count, 0),
    )?;
    class.define_method(
        "ends_with_xml_text?",
        magnus::method!(RbXmlText::ends_with_xml_text, 0),
    )?;
    class.define_method(
        "set_attribute",
        magnus::method!(RbXmlText::set_attribute, 2),
    )?;
    class.define_method("insert", magnus::method!(RbXmlText::insert, 2))?;
    class.define_method("insert_embed", magnus::method!(RbXmlText::insert_embed, 2))?;
    class.define_method(
        "push_xml_text",
        magnus::method!(RbXmlText::push_xml_text, 1),
    )?;
    class.define_method("xml_text", magnus::method!(RbXmlText::xml_text, 1))?;
    class.define_method("delete", magnus::method!(RbXmlText::delete, 2))?;
    class.define_method("clear", magnus::method!(RbXmlText::clear, 0))?;
    class.define_method(
        "insert_xml_text",
        magnus::method!(RbXmlText::insert_xml_text, 2),
    )?;
    class.define_method(
        "delete_xml_text",
        magnus::method!(RbXmlText::delete_xml_text, 1),
    )?;
    class.define_private_method(
        "native_relative_position",
        magnus::method!(RbXmlText::native_relative_position, 2),
    )?;
    class.define_private_method(
        "native_block_position",
        magnus::method!(RbXmlText::native_block_position, 0),
    )?;
    Ok(())
}
