# ProseMirror in Yjs Y.Doc: Research Documentation Index

## Overview

This directory contains comprehensive research on how ProseMirror documents are stored in Yjs Y.Doc CRDTs, with practical examples for Rust, Python, and Ruby.

## Documents

### 1. RESEARCH_SUMMARY.md (START HERE)
**Quick reference** - 5-10 minute read

**Contains**:
- Quick answers to all 5 research questions
- Key findings summary
- Feasibility assessment
- Data structure examples
- Code examples (Rust/Python)
- Recommendations by language

**Best for**: Getting oriented, decision making

### 2. PROSEMIRROR_YCRDT_ANALYSIS.md (DETAILED REFERENCE)
**Complete technical analysis** - 20KB, 10 major sections

**Contains**:
- Section 1: Data structures (Y.XmlFragment, XmlElement, XmlText, Map)
- Section 2: Schema encoding (how node types map)
- Section 3: Traversal examples (Rust code)
- Section 4: Yrs codebase examples
- Section 5: Existing libraries survey
- Section 6: Feasibility by language
- Section 7: Ruby implementation roadmap
- Section 8: Binary format (lib0 v1/v2)
- Section 9: CRDT vs schema comparison
- Section 10: Extraction strategies

**Best for**: Deep understanding, implementation planning

### 3. Y_CRDT_FFI_ANALYSIS.md (FFI INTERNALS)
**FFI technical details** - 25KB, 11 sections

**Contains**:
- Project structure overview
- YFFI module analysis
- Core FFI functions
- Memory management walkthrough
- Data types and structures
- Error codes
- Ruby gem implementation guide

**Best for**: Ruby gem development, FFI binding creation

### 4. QUICK_REFERENCE.md (FFI CHEAT SHEET)
**Quick FFI reference** - Quick scan format

**Contains**:
- 9 core FFI functions
- Copy-paste ready FFI bindings
- Ruby wrapper templates
- Usage examples
- Error code reference

**Best for**: FFI implementation, quick lookup

## Quick Navigation

### I want to...

**...understand the big picture**
1. Read RESEARCH_SUMMARY.md
2. Look at "Data Structure Examples" section
3. Review "Feasibility Assessment"

**...implement ProseMirror extraction in Rust**
1. Read RESEARCH_SUMMARY.md (5 min)
2. Copy code example from RESEARCH_SUMMARY.md
3. Reference PROSEMIRROR_YCRDT_ANALYSIS.md Sections 1-4

**...implement ProseMirror extraction in Python**
1. Read RESEARCH_SUMMARY.md (5 min)
2. Use pycrdt library (similar to yrs)
3. Follow Rust examples, adapt for Python

**...extend Ruby with XML reading**
1. Read RESEARCH_SUMMARY.md (5 min)
2. Read PROSEMIRROR_YCRDT_ANALYSIS.md Section 7 (Ruby roadmap)
3. Reference Y_CRDT_FFI_ANALYSIS.md Sections 1-3
4. Use QUICK_REFERENCE.md as FFI template

**...understand the binary format**
1. Read PROSEMIRROR_YCRDT_ANALYSIS.md Section 8
2. Reference Y_CRDT_FFI_ANALYSIS.md Section 5

**...validate ProseMirror against schema**
1. Read PROSEMIRROR_YCRDT_ANALYSIS.md Section 2
2. Read RESEARCH_SUMMARY.md "Validation" section
3. Implement custom validation logic

## Key Findings Summary

### Data Structures Used
- Y.XmlFragment (root container)
- Y.XmlElement (nodes)
- Y.XmlText (text content)
- Y.Map (attributes)

### Feasibility by Language
| Language | Read XML | Status | Notes |
|----------|----------|--------|-------|
| Rust | YES | ✓ | yrs crate |
| Python | YES | ✓ | pycrdt |
| Ruby | NO | ✗ | Needs FFI work |
| JavaScript | YES | ✓ | y.js |

### Can You Extract ProseMirror Without JS?
**YES** - Using Rust or Python bindings
**NO** - Not currently possible in pure Ruby

## File Locations

**In this directory**:
```
/Users/johncamara/Projects/yrb-lite/
├── RESEARCH_SUMMARY.md                    (Start here)
├── PROSEMIRROR_YCRDT_ANALYSIS.md          (Deep dive)
├── Y_CRDT_FFI_ANALYSIS.md                 (FFI details)
├── QUICK_REFERENCE.md                     (FFI reference)
└── RESEARCH_INDEX.md                      (This file)
```

**Source code referenced**:
```
/tmp/y-crdt-analysis/
├── yrs/src/types/xml.rs                  (XML implementation)
├── yrs/src/types/text.rs                 (Text implementation)
├── yrs/src/types/map.rs                  (Map implementation)
├── yrs/src/tests/compatibility_tests.rs  (ProseMirror example)
├── yffi/src/lib.rs                       (FFI bindings)
└── yrs/src/encoding/                     (Binary format)
```

## Implementation Checklist

### For Rust Implementation
- [ ] Review RESEARCH_SUMMARY.md code examples
- [ ] Study yrs::types::xml documentation
- [ ] Create traversal function
- [ ] Test on sample Y.Doc
- [ ] Add schema validation if needed

### For Python Implementation
- [ ] Install pycrdt
- [ ] Review yrs examples (similar API)
- [ ] Create traversal function
- [ ] Test on sample Y.Doc
- [ ] Compare with y-prosemirror output

### For Ruby Implementation (if needed)
- [ ] Review PROSEMIRROR_YCRDT_ANALYSIS.md Section 7
- [ ] Review Y_CRDT_FFI_ANALYSIS.md Sections 1-3
- [ ] Extend yffi with XML functions
- [ ] Create Ruby FFI bindings
- [ ] Write Ruby wrapper classes
- [ ] Test with existing yrb-lite infrastructure

## Key Concepts

### Y.XmlFragment
- Root container for ProseMirror document
- Ordered list of nodes
- Accessed via `doc.get_or_insert_xml_fragment("prosemirror")`

### Y.XmlElement
- Represents a ProseMirror node
- Has tag, attributes, children
- Traversed via `.children()` iterator

### Y.XmlText
- Inline text content
- Retrieved via `.get_string(txn)`
- Formatting stored as attributes

### State Vector
- Compact representation of document state
- Used for differential updates
- Enables efficient synchronization

### Binary Format (lib0)
- Variable-length integer encoding
- CRDT metadata (client ID, clock)
- Automatically handled by yrs

## Related Resources

**Official Projects**:
- yrs: https://docs.rs/yrs/
- y-prosemirror: https://github.com/yjs/y-prosemirror
- y-crdt: https://github.com/y-crdt/y-crdt

**Your Project**:
- yrb-lite: /Users/johncamara/Projects/yrb-lite

**Dependencies**:
- yrs v0.21+ (Rust CRDT)
- pycrdt (Python bindings)
- yrb-lite (Ruby bindings, work in progress)

## Version Information

**Analysis Date**: November 24, 2025
**Y-CRDT Version**: 0.24.0
**yrs Version**: 0.21+
**yrb-lite Version**: Current development

## Troubleshooting

**Q: I got lost reading the full analysis**
A: Start with RESEARCH_SUMMARY.md instead, then read specific sections of PROSEMIRROR_YCRDT_ANALYSIS.md

**Q: Ruby doesn't have XmlFragment support**
A: Correct. See RESEARCH_SUMMARY.md "Ruby Developers" for solutions

**Q: Can I use this without understanding CRDTs?**
A: Yes! Just treat Y.Doc as a tree structure. See Section 3 of PROSEMIRROR_YCRDT_ANALYSIS.md for traversal examples

**Q: Do I need a ProseMirror schema?**
A: Only for validation. Reading works without schema. See Section 2 of PROSEMIRROR_YCRDT_ANALYSIS.md

**Q: Which language should I use?**
A: Rust (best) > Python (good) > Ruby (needs FFI work)

## Quick Links

### By Task
- [Extract ProseMirror JSON](PROSEMIRROR_YCRDT_ANALYSIS.md#10-extraction-strategy)
- [Traverse XML Structure](PROSEMIRROR_YCRDT_ANALYSIS.md#3-traversing-crdt-structure-without-prosemirror)
- [Ruby Implementation](PROSEMIRROR_YCRDT_ANALYSIS.md#7-implementation-roadmap-for-ruby)
- [Binary Format Details](PROSEMIRROR_YCRDT_ANALYSIS.md#8-binary-format-details-lib0-v1v2)

### By Language
- [Rust Examples](PROSEMIRROR_YCRDT_ANALYSIS.md#3-traversing-crdt-structure-without-prosemirror)
- [Python Examples](PROSEMIRROR_YCRDT_ANALYSIS.md#102-python-example)
- [Ruby Roadmap](PROSEMIRROR_YCRDT_ANALYSIS.md#7-implementation-roadmap-for-ruby)

### By Concept
- [Data Structures](PROSEMIRROR_YCRDT_ANALYSIS.md#1-data-structures-used-by-y-prosemirror)
- [Schema Encoding](PROSEMIRROR_YCRDT_ANALYSIS.md#2-how-prosemirror-schema-is-encoded)
- [Feasibility](RESEARCH_SUMMARY.md#feasibility-assessment)
- [Existing Libraries](PROSEMIRROR_YCRDT_ANALYSIS.md#5-existing-libraries-for-decoding-prosemirror-from-yjs)

---

## How to Use These Documents Effectively

1. **First Time**: Read RESEARCH_SUMMARY.md (15 min)
2. **Implementation**: Use PROSEMIRROR_YCRDT_ANALYSIS.md as reference
3. **FFI Work**: Reference Y_CRDT_FFI_ANALYSIS.md and QUICK_REFERENCE.md
4. **Deep Dive**: Read full PROSEMIRROR_YCRDT_ANALYSIS.md (1-2 hours)

**Total reading time by depth**:
- Quick overview: 15 minutes
- Implementation: 30 minutes per language
- Full understanding: 2-3 hours
- FFI development: 4-6 hours

---

**Last Updated**: November 24, 2025
**Maintainer**: Research compiled by Claude Code
**License**: Same as yrb-lite project
