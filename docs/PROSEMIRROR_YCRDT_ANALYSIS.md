# ProseMirror Documents in Yjs Y.Doc CRDTs: Complete Technical Analysis

## Executive Summary

ProseMirror documents are stored in Yjs using **Y.XmlFragment** as the root container, which holds an ordered sequence of **Y.XmlElement** and **Y.XmlText** nodes that represent the ProseMirror document structure. While the binary encoding is Yjs-specific (lib0 v1/v2 format), the underlying CRDT data structures can be traversed and read WITHOUT a JavaScript runtime using Rust bindings. However, extracting ProseMirror content requires understanding the node/mark/attribute schema mapping.

---

## 1. Data Structures Used by y-prosemirror

### 1.1 Root Structure: Y.XmlFragment

ProseMirror documents are mapped to **Y.XmlFragment**, which represents an ordered sequence of top-level nodes.

```
Y.XmlFragment (root)
├── Y.XmlElement (node 1)
├── Y.XmlElement (node 2)
├── Y.XmlText (inline text)
└── Y.XmlElement (node 3)
```

**Rust Type**: `XmlFragmentRef` (in yrs/src/types/xml.rs)
```rust
#[repr(transparent)]
pub struct XmlFragmentRef(BranchPtr);

// Underlying storage
pub enum XmlOut {
    Element(XmlElementRef),
    Fragment(XmlFragmentRef),
    Text(XmlTextRef),
}
```

### 1.2 Node Representation: Y.XmlElement

Each ProseMirror node is a **Y.XmlElement** with:
- **tag**: The node type (e.g., "paragraph", "heading", "blockquote")
- **attributes**: Key-value pairs storing node metadata (e.g., `{"level": 2}` for h2)
- **children**: Ordered array of nested Y.XmlElements and Y.XmlTexts

**Rust Type**: `XmlElementRef`
```rust
pub struct XmlElementRef(BranchPtr);

impl XmlElementRef {
    pub fn tag(&self) -> &Arc<str>  // e.g., "paragraph"
    pub fn children<'a, T: ReadTxn>(&self, txn: &'a T) -> XmlNodes<'a, T>
    pub fn get_attribute(&self, name: &str, txn: &T) -> Option<String>
    pub fn attributes(&self, txn: &T) -> impl Iterator<Item = (String, Any)>
}
```

### 1.3 Inline Content: Y.XmlText and Marks

Inline text is stored in **Y.XmlText**, which:
- Contains the actual text string
- Can have formatting attributes (marks) applied to ranges

**Rust Type**: `XmlTextRef`
```rust
pub struct XmlTextRef(BranchPtr);

impl XmlTextRef {
    pub fn get_string<T: ReadTxn>(&self, txn: &T) -> String
    pub fn attributes(&self, txn: &T) -> impl Iterator<Item = (String, String)>
    pub fn diff<T: ReadTxn>(&self, txn: &T, f: F) -> Vec<Diff>
    // Diff includes: text + formatting attributes per range
}
```

**Example Structure** (ProseMirror doc with mixed content):
```
<doc>
  <paragraph>
    <text marks="bold">Hello </text>
    <text>world</text>
  </paragraph>
  <heading level="2">
    <text>Title</text>
  </heading>
</doc>
```

Maps to Yjs as:
```
Y.XmlFragment
├── Y.XmlElement (tag: "paragraph")
│   └── Y.XmlText ("Hello world")  [marks applied to ranges]
└── Y.XmlElement (tag: "heading", attr: level=2)
    └── Y.XmlText ("Title")
```

### 1.4 Attributes Storage: Y.Map

Each XML node stores attributes in an internal **Y.Map** (HashMap in Rust terms).

**Rust Type**: `MapRef`
```rust
pub struct MapRef(BranchPtr);

impl MapRef {
    pub fn get(&self, txn: &T, key: &str) -> Option<Out>
    pub fn iter(&self, txn: &T) -> impl Iterator<Item = (&str, Out)>
    pub fn to_json(&self, txn: &T) -> Any  // Convert to JSON-like structure
}
```

### 1.5 Collections

Y.XmlFragment children are stored as an **ordered sequence** (similar to Y.Array).

**Traversal Methods**:
```rust
// Get all direct children (not recursive)
pub fn children<'a, T: ReadTxn>(&self, txn: &'a T) -> XmlNodes<'a, T> {
    let iter = BlockIter::new(BranchPtr::from(self.as_ref()));
    XmlNodes::new(iter, txn)
}

// Get all descendants (depth-first)
pub fn successors<'a, T: ReadTxn>(&'a self, txn: &'a T) -> TreeWalker<'a, &'a T, T> {
    TreeWalker::new(self.as_ref(), txn)
}
```

---

## 2. How ProseMirror Schema is Encoded

### 2.1 Schema Information Storage

The ProseMirror schema itself is NOT stored in the Y.Doc. Instead:

1. **Schema is assumed to be known** by both client and server
2. **Only document state is stored** in the Y.Doc
3. **Validation** happens at the application layer, not in the CRDT

This means:
- You need the ProseMirror schema definition to decode nodes properly
- Node types come from the Y.XmlElement tag attribute
- Attributes are stored as-is (strings mostly, with some type conversion)

### 2.2 Encoding Example

**ProseMirror Node**:
```json
{
  "type": "paragraph",
  "content": [
    {
      "type": "text",
      "text": "Hello",
      "marks": [{"type": "bold"}]
    }
  ]
}
```

**Yjs Encoding (XML structure)**:
```
Y.XmlFragment
└── Y.XmlElement
    ├── type="paragraph"
    ├── children: [
    │   └── Y.XmlText
    │       ├── text="Hello"
    │       └── format(0, 5, {"bold": true})
    └── ]
```

**Binary Encoding** (lib0 v2 format):
```
[OpType]
[ClientID][Clock]  # CRDT metadata
[Type][Length][Data]  # Payload
...
```

The binary format is documented in the lib0 specification, but key points:
- Uses variable-length integer encoding (varint)
- Includes CRDT operation metadata (client ID, clock)
- Supports multiple content types (string, embed, binary)

---

## 3. Traversing CRDT Structure Without ProseMirror

### 3.1 Reading XML Structure in Rust

You CAN extract content without ProseMirror, but you must manually reconstruct the document structure:

```rust
use yrs::{Doc, ReadTxn, XmlFragment};

fn traverse_xml(doc: &Doc) -> Result<(), Box<dyn std::error::Error>> {
    let txn = doc.transact();  // Read-only transaction
    
    // Get root fragment
    let root: XmlFragmentRef = doc.get_or_insert_xml_fragment("prosemirror");
    
    // Iterate over top-level nodes
    for xml_node in root.children(&txn) {
        match xml_node {
            XmlOut::Element(elem) => {
                let tag = elem.tag();  // e.g., "paragraph"
                println!("Element: <{}>", tag);
                
                // Get attributes
                for (key, value) in elem.attributes(&txn) {
                    println!("  @{}={:?}", key, value);
                }
                
                // Get children recursively
                traverse_children(&elem, &txn);
            }
            XmlOut::Text(text) => {
                let content = text.get_string(&txn);
                println!("Text: {}", content);
            }
            XmlOut::Fragment(frag) => {
                println!("Fragment (nested)");
                for child in frag.children(&txn) {
                    // Process recursively
                }
            }
        }
    }
    Ok(())
}

fn traverse_children<T: ReadTxn>(elem: &XmlElementRef, txn: &T) {
    for child in elem.children(txn) {
        match child {
            XmlOut::Element(child_elem) => {
                println!("  <{}> ...", child_elem.tag());
            }
            XmlOut::Text(text) => {
                println!("  \"{}\"", text.get_string(txn));
            }
            _ => {}
        }
    }
}
```

### 3.2 Reading with Deltas (Formatted Text)

For formatted text with marks:

```rust
use yrs::types::text::Diff;

fn read_formatted_text<T: ReadTxn>(text: &XmlTextRef, txn: &T) {
    // Get text with formatting information
    let deltas: Vec<Diff> = text.diff(txn, YChange::identity);
    
    for delta in deltas {
        println!("Text: {}", delta.insert);
        if let Some(attrs) = delta.attributes {
            println!("  Marks: {:?}", attrs);
        }
    }
}
```

### 3.3 Converting to JSON

Get the entire subtree as JSON:

```rust
use yrs::types::ToJson;

fn to_json<T: ReadTxn>(elem: &XmlElementRef, txn: &T) -> serde_json::Value {
    // XmlElementRef can be converted to JSON via the ToJson trait
    // But this requires the Any type which is complex
    
    // Manual approach:
    let mut obj = serde_json::json!({
        "type": elem.tag(),
    });
    
    // Add attributes
    for (k, v) in elem.attributes(txn) {
        obj[k] = v.to_json(txn);
    }
    
    // Add children
    let mut children = Vec::new();
    for child in elem.children(txn) {
        match child {
            XmlOut::Element(e) => children.push(to_json(&e, txn)),
            _ => {}
        }
    }
    if !children.is_empty() {
        obj["children"] = serde_json::Value::Array(children);
    }
    
    obj
}
```

---

## 4. Rust Examples in y-crdt Codebase

### 4.1 Reading XML/Text Types

**File**: `/tmp/y-crdt-analysis/yrs/src/types/xml.rs` (lines 285-308)

```rust
impl GetString for XmlElementRef {
    fn get_string<T: ReadTxn>(&self, txn: &T) -> String {
        let tag: &str = self.tag();
        let inner = self.0;
        let mut s = String::new();
        write!(&mut s, "<{}", tag).unwrap();
        
        // Read attributes
        let attributes = Attributes(inner.entries(txn));
        for (k, v) in attributes {
            write!(&mut s, " {}=\"{}\"", k, v).unwrap();
        }
        write!(&mut s, ">").unwrap();
        
        // Traverse children
        for i in inner.iter(txn) {
            if !i.is_deleted() {
                for content in i.content.get_content() {
                    write!(&mut s, "{}", content.to_string(txn)).unwrap();
                }
            }
        }
        write!(&mut s, "</{}>", tag).unwrap();
        s
    }
}
```

### 4.2 Compatibility Test Example

**File**: `/tmp/y-crdt-analysis/yrs/src/tests/compatibility_tests.rs`

```rust
let doc = Doc::new();
let xml = doc.get_or_insert_xml_fragment("prosemirror");
let mut txn = doc.transact_mut();
let update = Update::decode_v2(binary_data).unwrap();
txn.apply_update(update).unwrap();

// Extract element
let actual: XmlElementRef = xml.get(&txn, 0)
    .unwrap()
    .try_into()
    .unwrap();

// Get attributes
let attrs: HashMap<String, String> = actual
    .attributes(&txn)
    .map(|(k, v)| (k.to_string(), v.to_string(&txn)))
    .collect();
```

---

## 5. Existing Libraries for Decoding ProseMirror from Yjs

### 5.1 Rust Solutions

**Direct CRDT Access** (Recommended):
- **yrs** (v0.21+) - Full Rust implementation with XML support
  - License: MIT
  - Status: Production-ready
  - Can read XML structures directly from Y.Doc
  - Supports state vectors, updates, transactions
  - No JavaScript runtime needed

**FFI Bindings**:
- **yffi** - C/FFI wrapper around yrs
  - Provides C API for non-Rust languages
  - Used by Ruby (yrb), Python (pycrdt), etc.
  - Minimal: applyUpdate, encodeStateAsUpdate, transactions

### 5.2 Ruby Solutions

**yrb** / **yrb-lite**:
- Ruby gem bindings to yrs via FFI
- **Status**: Early stage, limited features
- **Current State**: Only applyUpdate and encodeStateAsUpdate
- **Missing**: Direct XML/XmlFragment access (not exposed in Ruby API yet)

```ruby
require 'yrb-lite'

doc = YrbLite::Doc.new
doc.apply_update(binary_update)
state_vector = doc.state_vector
```

**What's NOT available in yrb-lite**:
- XmlFragment/XmlElement access
- Text content extraction
- Attribute reading
- Traversal without JavaScript

**Solution**: Use yrs directly via FFI, or add Rust methods to yffi to expose XML reading.

### 5.3 JavaScript/Node.js

**y-prosemirror** (Official):
- GitHub: https://github.com/yjs/y-prosemirror
- NPM: y-prosemirror
- Complete binding with schema support
- Includes ProseMirror plugin integration

**y-protocols**:
- Lower-level Yjs protocol handling
- Can read raw Y.Doc structures

### 5.4 Python

**pycrdt**:
- Python bindings to yrs
- Similar feature parity to yrb
- No XML access yet

---

## 6. Can You Extract ProseMirror Without JS Runtime?

### 6.1 YES - With Limitations

**You CAN:**
- Read Y.Doc binary updates (all languages via YFFI)
- Traverse XmlFragment/XmlElement structures (Rust via yrs, Python via pycrdt)
- Extract text content (any language that binds yrs)
- Read attributes (Rust/Python only, currently)

**Example** (Rust):
```rust
let doc = Doc::new();
doc.transact_mut_while(|txn| {
    let xml = doc.get_or_insert_xml_fragment("prosemirror");
    
    // Get first node
    if let Some(first) = xml.get(txn, 0) {
        if let XmlOut::Element(elem) = first {
            println!("Tag: {}", elem.tag());
            println!("Text: {}", /* extract text */);
        }
    }
    Ok(())
});
```

### 6.2 NO - For Complex Scenarios

**You CANNOT (without reimplementation):**
- Validate against ProseMirror schema (schema must be provided separately)
- Apply ProseMirror document updates (use CRDT updates instead)
- Use ProseMirror plugins/transformations
- Handle marks > simple attributes

**Why**: ProseMirror's data model has semantic meaning (marks with ranges, complex schemas) that the CRDT doesn't encode. The CRDT just stores structure + attributes.

### 6.3 Feasibility by Language

| Language | Read X MLElement | Read Text | Read Attributes | Traverse | Status |
|----------|-----------------|-----------|-----------------|----------|--------|
| Rust     | YES             | YES       | YES             | YES      | ✓      |
| Python   | YES (pycrdt)    | YES       | YES             | YES      | ✓      |
| Ruby     | NO              | NO        | NO              | NO       | ✗      |
| Node.js  | YES (y.js)      | YES       | YES             | YES      | ✓      |
| Go       | YES (ygo)       | YES       | YES             | YES      | ✓      |

**Ruby Status**: yrb-lite currently lacks XML access. To add it:
1. Extend yffi FFI with XML reading functions
2. Create Ruby wrappers around them
3. Or call yrs Rust methods directly

---

## 7. Implementation Roadmap for Ruby

### 7.1 Current State

```ruby
doc = YrbLite::Doc.new
doc.apply_update(binary_update)  # Works
doc.encode_state_as_update       # Works
# doc.get_xml_fragment() - NOT IMPLEMENTED
```

### 7.2 What Would Be Needed

```rust
// Add to yffi/src/lib.rs

#[repr(C)]
pub struct XmlFragment {
    pub ptr: *mut Branch,
}

#[repr(C)]
pub struct XmlElement {
    pub ptr: *mut Branch,
    pub tag: *const c_char,
}

#[repr(C)]
pub struct XmlNode {
    pub node_type: u8,  // 0=Element, 1=Text, 2=Fragment
    pub data: *mut c_void,
}

// FFI functions needed
#[no_mangle]
pub extern "C" fn ydoc_get_xml_fragment(doc: *const Doc, name: *const c_char) -> *mut XmlFragment;

#[no_mangle]
pub extern "C" fn yxml_fragment_get_child(frag: *const XmlFragment, index: u32) -> XmlNode;

#[no_mangle]
pub extern "C" fn yxml_element_get_attribute(elem: *const XmlElement, name: *const c_char) -> *const c_char;

#[no_mangle]
pub extern "C" fn yxml_get_string(ptr: *const XmlNode) -> *const c_char;
```

Then in Ruby:
```ruby
class YrbLite::XmlFragment
  def get_child(index)
    # Call FFI function
  end
  
  def each_child
    # Iterate children
  end
end

doc = YrbLite::Doc.new
root = doc.get_xml_fragment("prosemirror")
root.each_child do |node|
  puts node.type  # "paragraph", "heading", etc.
end
```

---

## 8. Binary Format Details (lib0 v1/v2)

### 8.1 Update Structure

Y.Doc updates are encoded in lib0 format:

```
Update ::= [Item]+
Item ::= [Marker][... content depends on marker ...]

Markers:
  0x00: Content (string/embed/etc.)
  0x01: Skip (deletion marker)
  0x02: Format (formatting information)
  etc.
```

**Reading Updates**:
```rust
use yrs::Update;

let binary = /* received bytes */;
let update = Update::decode_v2(binary)?;  // Parses binary into operations

let doc = Doc::new();
doc.transact_mut_while(|txn| {
    txn.apply_update(update)?;
    Ok(())
});
```

### 8.2 State Vector Structure

State vectors are compressed representation of document state:

```
StateVector ::= [ClientID][Clock]+

ClientID: u32 (peer identifier)
Clock: u32 (maximum sequence number seen from that peer)
```

Example:
```
State Vector: ClientID=1, Clock=42; ClientID=2, Clock=15
Meaning: Peer 1 has made 42 edits, Peer 2 has made 15 edits
```

---

## 9. Comparison: CRDT vs Schema-Aware Systems

### 9.1 What Yjs/CRDT Provides

✓ Conflict-free merging
✓ Structure (parent/child relationships)
✓ Attributes (key-value pairs)
✓ Sequence (ordered nodes)
✓ Text with formatting ranges
✗ Schema validation
✗ Node type constraints
✗ Mark semantics

### 9.2 What ProseMirror Adds

✓ Schema validation
✓ Mark definitions with semantics
✓ Document transformation rules
✓ Plugin system
✗ Conflict resolution (uses Yjs instead)

**Implication**: You can read Y.Doc + reconstruct ProseMirror JSON IF you have the schema, but you need application-level validation.

---

## 10. Extraction Strategy

### 10.1 Recommended Approach

For reading ProseMirror from Y.Doc without ProseMirror library:

1. **Get the binary update** → `doc.encode_state_as_update()`
2. **Create fresh Yrs document** → `let doc = Doc::new()`
3. **Apply update** → `txn.apply_update(update)?`
4. **Traverse structure** → Use XmlFragmentRef/XmlElementRef
5. **Extract to JSON** → Write custom serializer

### 10.2 Python Example

```python
from pycrdt import Doc
import json

# Load update into doc
doc = Doc()
doc.apply_update(binary_update)

# Get XML fragment
root = doc.get_xml_fragment("prosemirror")

def extract_node(xml_node, txn):
    if isinstance(xml_node, XmlElement):
        return {
            "type": xml_node.tag,
            "attrs": {k: v for k, v in xml_node.attrs(txn).items()},
            "children": [
                extract_node(child, txn)
                for child in xml_node.children(txn)
            ]
        }
    elif isinstance(xml_node, XmlText):
        return {
            "type": "text",
            "text": xml_node.get_string(txn)
        }

# Convert to ProseMirror JSON
content = []
txn = doc.begin_transaction()
for child in root.children(txn):
    content.append(extract_node(child, txn))
txn.commit()

pm_json = {
    "type": "doc",
    "content": content
}
```

### 10.3 Rust Example (Full Solution)

```rust
use yrs::{Doc, XmlFragmentRef, XmlOut, ReadTxn};
use serde_json::json;

fn extract_prosemirror_json(doc: &Doc) -> serde_json::Value {
    let txn = doc.transact();
    let root = doc.get_or_insert_xml_fragment("prosemirror");
    
    let mut content = Vec::new();
    for child in root.children(&txn) {
        content.push(extract_node(&child, &txn));
    }
    
    json!({
        "type": "doc",
        "content": content
    })
}

fn extract_node(node: &XmlOut, txn: &impl ReadTxn) -> serde_json::Value {
    match node {
        XmlOut::Element(elem) => {
            let mut attrs = serde_json::Map::new();
            for (k, v) in elem.attributes(txn) {
                attrs.insert(k, serde_json::Value::String(v.to_string(txn)));
            }
            
            let mut children = Vec::new();
            for child in elem.children(txn) {
                children.push(extract_node(&child, txn));
            }
            
            let mut obj = json!({
                "type": elem.tag().to_string(),
                "attrs": attrs
            });
            if !children.is_empty() {
                obj["content"] = serde_json::Value::Array(children);
            }
            obj
        }
        XmlOut::Text(text) => {
            json!({
                "type": "text",
                "text": text.get_string(txn)
            })
        }
        XmlOut::Fragment(_) => json!({ "type": "fragment" })
    }
}
```

---

## Summary: Feasibility Assessment

| Task | Feasible? | Language | Notes |
|------|-----------|----------|-------|
| Read Y.Doc binary | YES | All | YFFI available |
| Traverse XmlElement | YES | Rust, Python | Direct in yrs/pycrdt |
| Read text content | YES | Rust, Python | GetString trait |
| Read attributes | YES | Rust, Python | attributes() method |
| Extract to JSON | YES | Rust, Python | Manual implementation |
| Without JS Runtime | YES | Rust, Python | No, Ruby (yet) |
| Validate against schema | YES | Conditional | Need schema + implementation |
| Extract ProseMirror | YES | Rust, Python | Possible with mapping |

**Best Solution**: Use Rust via yrs, or Python via pycrdt. Ruby needs FFI extension to yffi.

