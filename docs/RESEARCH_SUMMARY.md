# ProseMirror in Yjs Y.Doc: Research Summary

## Quick Answers to Your Questions

### 1. What data structures does y-prosemirror use?

**Primary Structures**:
- **Y.XmlFragment** - Root container (ordered list of nodes)
- **Y.XmlElement** - Individual nodes (tag + attributes + children)
- **Y.XmlText** - Inline text content with formatting
- **Y.Map** - Attribute storage (internal, one per XmlElement)

**Rust Types** (from yrs crate):
```rust
XmlFragmentRef  // Container for nodes
XmlElementRef   // Node with tag, attrs, children
XmlTextRef      // Text with formatting ranges
```

### 2. How is ProseMirror's document schema encoded?

**Answer: It's NOT.**

The schema is external. Only document state is stored in Y.Doc:
- Node types come from XmlElement.tag (e.g., "paragraph", "heading")
- Node attributes stored as XmlElement attributes
- Text content in XmlText nodes
- Formatting (marks) as attributes on text ranges

The CRDT doesn't know about your ProseMirror schema. Validation happens at application level.

### 3. Can you traverse the CRDT structure without ProseMirror?

**YES** - Use Rust or Python bindings:

```rust
let root = doc.get_or_insert_xml_fragment("prosemirror");
for child in root.children(&txn) {
    match child {
        XmlOut::Element(elem) => {
            println!("Node: {}", elem.tag());
            for (k, v) in elem.attributes(&txn) {
                println!("  @{} = {}", k, v);
            }
        }
        _ => {}
    }
}
```

### 4. Rust/Ruby examples in y-crdt codebase?

**Found**: Yes, in `/tmp/y-crdt-analysis/yrs/src/types/xml.rs`:
- Lines 285-308: XmlElementRef::get_string() shows how to traverse
- Lines 645-675: XmlTextRef::as_prelim() shows attribute reading
- Tests in compatibility_tests.rs show ProseMirror example

**Ruby examples**: Currently MISSING. yrb-lite doesn't expose XML reading.

### 5. Existing Rust/Ruby libraries for decoding ProseMirror?

| Language | Library | Status | Can Read XML? |
|----------|---------|--------|---------------|
| Rust | yrs | ✓ Production | YES |
| Python | pycrdt | ✓ Production | YES |
| Ruby | yrb-lite | ✗ Early | NO |
| JavaScript | y.js | ✓ Standard | YES |
| JavaScript | y-prosemirror | ✓ Official | YES |

---

## Key Findings

### Finding 1: ProseMirror is Mapped to XML

ProseMirror documents use this mapping:
```
ProseMirror Node Tree
       ↓
Y.XmlFragment (root)
    ├── Y.XmlElement (node type = tag)
    │   ├── attributes (node attrs)
    │   └── children (Y.XmlElement|Y.XmlText)
    └── ...
```

### Finding 2: Binary Format is lib0 V1/V2

Updates are encoded in lib0 format:
```
[Marker][ClientID][Clock][Content Type][Length][Payload]
```
Parsing requires lib0 decoder, handled by yrs automatically.

### Finding 3: You CAN Read Without JavaScript

**Feasible** using:
- Rust with yrs crate (direct, no FFI)
- Python with pycrdt (direct, no FFI)
- Ruby with yrb-lite (requires FFI extension)

**NOT feasible in pure Ruby** - needs Rust bindings.

### Finding 4: Y.Doc ≠ ProseMirror

Important distinction:
- Y.Doc stores **structure + attributes**
- ProseMirror stores **structure + schema + validation**
- You can extract structure without schema, but validation requires external schema definition

### Finding 5: Ruby Gap

yrb-lite currently supports:
- ✓ apply_update(binary)
- ✓ encode_state_as_update()
- ✗ get_xml_fragment()
- ✗ XmlElement traversal
- ✗ Attribute reading

To add: Extend yffi FFI with XML reading functions.

---

## Feasibility Assessment

### Extract ProseMirror Content in Rust?
**YES** - Production ready
```rust
use yrs::Doc;
let doc = Doc::new();
// Apply update...
let root = doc.get_or_insert_xml_fragment("prosemirror");
// Traverse and extract
```

### Extract ProseMirror Content in Python?
**YES** - Production ready
```python
from pycrdt import Doc
doc = Doc()
# Apply update...
root = doc.get_xml_fragment("prosemirror")
# Traverse and extract
```

### Extract ProseMirror Content in Ruby?
**NO** - Currently not possible
- yrb-lite lacks XmlFragment API
- Would need to extend yffi with XML functions
- Then create Ruby FFI bindings

### Extract Without JavaScript Runtime?
**YES** - Rust and Python only
- Node.js uses y.js (includes JS runtime)
- Rust/Python use native bindings

### Validate Against Schema?
**CONDITIONAL**:
- Y.Doc has no schema validation
- Need external ProseMirror schema definition
- Implement validation logic in application code

---

## Data Structure Examples

### Simple Document

```
ProseMirror JSON:
{
  "type": "doc",
  "content": [
    {
      "type": "paragraph",
      "content": [
        {"type": "text", "text": "Hello"}
      ]
    }
  ]
}

Yjs Storage:
Y.XmlFragment (root)
└── Y.XmlElement (tag="paragraph")
    └── Y.XmlText ("Hello")
```

### Document with Attributes

```
ProseMirror:
{
  "type": "heading",
  "attrs": {"level": 2},
  "content": [
    {"type": "text", "text": "Title"}
  ]
}

Yjs:
Y.XmlElement (tag="heading")
├── attributes: {"level": "2"}
└── Y.XmlText ("Title")
```

### Document with Marks

```
ProseMirror:
{
  "type": "text",
  "text": "Hello world",
  "marks": [
    {"type": "bold", "from": 0, "to": 5}
  ]
}

Yjs:
Y.XmlText ("Hello world")
├── format(0, 5, {"bold": true})
```

---

## Code Examples

### Reading in Rust

```rust
use yrs::{Doc, ReadTxn, XmlOut};

fn extract_text(doc: &Doc) -> String {
    let txn = doc.transact();
    let root = doc.get_or_insert_xml_fragment("prosemirror");
    
    let mut result = String::new();
    for child in root.children(&txn) {
        if let XmlOut::Text(text) = child {
            result.push_str(&text.get_string(&txn));
        }
    }
    result
}
```

### Reading in Python

```python
from pycrdt import Doc

doc = Doc()
# ... apply_update ...

root = doc.get_xml_fragment("prosemirror")
for child in root.children():
    if hasattr(child, 'tag'):
        print(f"Node: {child.tag}")
        for key, value in child.attributes.items():
            print(f"  @{key} = {value}")
```

---

## Recommendations

### For Rust Developers
✓ Use yrs directly - full XML support, production-ready
✓ Can read arbitrary Y.Doc structures
✓ No JavaScript dependency

### For Python Developers
✓ Use pycrdt - similar to yrs, Python native
✓ Full XML support
✓ No JavaScript dependency

### For Ruby Developers
Option 1: Extend yrb-lite
- Add yffi FFI bindings for XmlFragment
- Create Ruby wrappers
- 2-4 weeks work estimate

Option 2: Use subprocess to call Rust
- Simple Python wrapper
- Pipe binary updates
- Less efficient but works today

Option 3: Use Node.js subprocess
- Call y.js via node
- Extract to JSON
- Not ideal but viable

### For Extracting ProseMirror JSON

**Recommended Flow**:
1. Get binary update from Y.Doc
2. Create fresh doc with yrs/pycrdt
3. Apply update
4. Traverse XmlFragment tree
5. Serialize to JSON
6. (Optional) Validate against schema

---

## Related Documents

1. **PROSEMIRROR_YCRDT_ANALYSIS.md** - Detailed technical analysis (752 lines)
2. **Y_CRDT_FFI_ANALYSIS.md** - FFI internals (25KB, 11 sections)
3. **QUICK_REFERENCE.md** - Quick FFI reference
4. **Y.CRDT Tests** - Compatibility tests in yrs source

---

## References

**Source Repositories**:
- Y-CRDT: https://github.com/y-crdt/y-crdt (Rust)
- yrs: https://docs.rs/yrs/ (Rust CRDT)
- y-prosemirror: https://github.com/yjs/y-prosemirror (Official)
- yrb-lite: /Users/johncamara/Projects/yrb-lite (Your project)

**Standards**:
- lib0: Efficient binary encoding format
- Yjs Protocol: Version compatibility
- ProseMirror Schema: Node/Mark definitions

---

**Analysis Date**: November 24, 2025
**Sources**: y-crdt v0.24.0, yrs 0.21+, yrb-lite
**Feasibility**: YES for Rust/Python, NO for Ruby (without FFI work)
