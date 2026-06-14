// Run with: node test/fixtures/generate_fixtures.mjs
// Requires: npm install yjs

import * as Y from 'yjs'

function toBase64(uint8Array) {
  return Buffer.from(uint8Array).toString('base64')
}

console.log("// Y.js Test Fixtures for yrb-lite")
console.log("// Generated from yjs version:", Y.Doc ? "0.x" : "unknown")
console.log("")

// Fixture 1: Simple text document
{
  const doc = new Y.Doc()
  doc.clientID = 1
  const text = doc.getText('content')
  text.insert(0, 'hello world')

  const update = Y.encodeStateAsUpdate(doc)
  const sv = Y.encodeStateVector(doc)

  console.log("# Fixture 1: Text with 'hello world'")
  console.log("CLIENT_ID = 1")
  console.log(`UPDATE = "${toBase64(update)}"`)
  console.log(`STATE_VECTOR = "${toBase64(sv)}"`)
  console.log("")
}

// Fixture 2: Two docs syncing
{
  const doc1 = new Y.Doc()
  doc1.clientID = 1
  const text1 = doc1.getText('content')
  text1.insert(0, 'from doc1')

  const doc2 = new Y.Doc()
  doc2.clientID = 2
  const text2 = doc2.getText('content')
  text2.insert(0, 'from doc2')

  // Get updates for syncing
  const update1 = Y.encodeStateAsUpdate(doc1)
  const update2 = Y.encodeStateAsUpdate(doc2)

  // Apply to each other
  Y.applyUpdate(doc1, update2)
  Y.applyUpdate(doc2, update1)

  // After sync, both should have same state
  const mergedUpdate = Y.encodeStateAsUpdate(doc1)
  const mergedSv = Y.encodeStateVector(doc1)

  console.log("# Fixture 2: Two docs merged")
  console.log(`DOC1_UPDATE = "${toBase64(update1)}"`)
  console.log(`DOC2_UPDATE = "${toBase64(update2)}"`)
  console.log(`MERGED_UPDATE = "${toBase64(mergedUpdate)}"`)
  console.log(`MERGED_STATE_VECTOR = "${toBase64(mergedSv)}"`)
  console.log("")
}

// Fixture 3: Sync protocol messages
{
  const doc1 = new Y.Doc()
  doc1.clientID = 1
  const text1 = doc1.getText('content')
  text1.insert(0, 'synced content')

  const doc2 = new Y.Doc()
  doc2.clientID = 2

  // Simulate sync protocol
  // Step 1: doc2 sends its state vector to doc1
  const sv2 = Y.encodeStateVector(doc2)

  // Step 2: doc1 computes diff and sends update
  const diffUpdate = Y.encodeStateAsUpdate(doc1, sv2)

  // Step 3: doc2 applies the update
  Y.applyUpdate(doc2, diffUpdate)

  // Now both should match
  const finalSv1 = Y.encodeStateVector(doc1)
  const finalSv2 = Y.encodeStateVector(doc2)

  console.log("# Fixture 3: Sync protocol")
  console.log(`INITIAL_SV_DOC2 = "${toBase64(sv2)}"`)
  console.log(`DIFF_UPDATE = "${toBase64(diffUpdate)}"`)
  console.log(`FINAL_SV = "${toBase64(finalSv1)}"`)
  console.log(`SV_MATCH = ${toBase64(finalSv1) === toBase64(finalSv2)}`)
  console.log("")
}

// Fixture 4: Empty doc state vector (for baseline)
{
  const doc = new Y.Doc()
  doc.clientID = 1
  const sv = Y.encodeStateVector(doc)
  const update = Y.encodeStateAsUpdate(doc)

  console.log("# Fixture 4: Empty doc")
  console.log(`EMPTY_SV = "${toBase64(sv)}"`)
  console.log(`EMPTY_UPDATE = "${toBase64(update)}"`)
}
