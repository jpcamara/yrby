#!/usr/bin/env node
// Y.js Fixture Generator for yrb-lite interop testing
// Run with: bun run test/fixtures/yjs_generator.mjs [command] [args...]

// Suppress Y.js warnings by redirecting console.log/warn to stderr
const originalLog = console.log
const originalWarn = console.warn
console.log = (...args) => {
  if (args[0]?.toString().includes('[yjs]')) {
    console.error(...args)
  } else {
    originalLog(...args)
  }
}
console.warn = console.error

import * as Y from 'yjs'

function toBase64(uint8Array) {
  return Buffer.from(uint8Array).toString('base64')
}

function fromBase64(base64) {
  return new Uint8Array(Buffer.from(base64, 'base64'))
}

const commands = {
  // Generate a document with text content
  'create-doc': (clientId, fieldName, content) => {
    const doc = new Y.Doc()
    doc.clientID = parseInt(clientId)
    const text = doc.getText(fieldName)
    text.insert(0, content)

    return JSON.stringify({
      update: toBase64(Y.encodeStateAsUpdate(doc)),
      state_vector: toBase64(Y.encodeStateVector(doc)),
      client_id: doc.clientID
    })
  },

  // Generate empty doc state
  'empty-doc': (clientId = '1') => {
    const doc = new Y.Doc()
    doc.clientID = parseInt(clientId)

    return JSON.stringify({
      update: toBase64(Y.encodeStateAsUpdate(doc)),
      state_vector: toBase64(Y.encodeStateVector(doc)),
      client_id: doc.clientID
    })
  },

  // Apply an update and return the resulting state
  // Use a high client ID to avoid conflicts with updates being applied
  'apply-update': (base64Update, clientId = '999999') => {
    const doc = new Y.Doc()
    doc.clientID = parseInt(clientId)
    Y.applyUpdate(doc, fromBase64(base64Update))

    return JSON.stringify({
      update: toBase64(Y.encodeStateAsUpdate(doc)),
      state_vector: toBase64(Y.encodeStateVector(doc)),
      client_id: doc.clientID
    })
  },

  // Compute diff update given a state vector
  'diff-update': (base64DocUpdate, base64StateVector) => {
    const doc = new Y.Doc()
    Y.applyUpdate(doc, fromBase64(base64DocUpdate))
    // encodeStateAsUpdate accepts raw state vector bytes directly
    const svBytes = fromBase64(base64StateVector)
    const diff = Y.encodeStateAsUpdate(doc, svBytes)

    return JSON.stringify({
      diff_update: toBase64(diff)
    })
  },

  // Merge two updates and return result
  'merge-updates': (base64Update1, base64Update2) => {
    const doc = new Y.Doc()
    Y.applyUpdate(doc, fromBase64(base64Update1))
    Y.applyUpdate(doc, fromBase64(base64Update2))

    return JSON.stringify({
      merged_update: toBase64(Y.encodeStateAsUpdate(doc)),
      state_vector: toBase64(Y.encodeStateVector(doc))
    })
  },

  // Get text content from a document
  'get-text': (base64Update, fieldName) => {
    const doc = new Y.Doc()
    Y.applyUpdate(doc, fromBase64(base64Update))
    const text = doc.getText(fieldName)

    return JSON.stringify({
      content: text.toString(),
      length: text.length
    })
  },

  // Verify state vectors match (byte comparison)
  'verify-sv': (base64Sv1, base64Sv2) => {
    const sv1 = fromBase64(base64Sv1)
    const sv2 = fromBase64(base64Sv2)

    // Simple byte comparison
    const match = sv1.length === sv2.length &&
      sv1.every((byte, i) => byte === sv2[i])

    return JSON.stringify({ match })
  },

  // Generate sync step 1 (state vector request)
  'sync-step1': (clientId = '1') => {
    const doc = new Y.Doc()
    doc.clientID = parseInt(clientId)

    return JSON.stringify({
      state_vector: toBase64(Y.encodeStateVector(doc))
    })
  },

  // Generate sync step 2 (update response)
  'sync-step2': (base64DocUpdate, base64StateVector) => {
    const doc = new Y.Doc()
    Y.applyUpdate(doc, fromBase64(base64DocUpdate))
    const svBytes = fromBase64(base64StateVector)
    const update = Y.encodeStateAsUpdate(doc, svBytes)

    return JSON.stringify({
      update: toBase64(update)
    })
  },

  'version': () => {
    return JSON.stringify({
      runtime: 'yjs',
      version: '13.6.x'
    })
  }
}

// Main
const [command, ...args] = process.argv.slice(2)

if (!command || !commands[command]) {
  console.error('Usage: yjs_generator.mjs <command> [args...]')
  console.error('Commands:', Object.keys(commands).join(', '))
  process.exit(1)
}

try {
  console.log(commands[command](...args))
} catch (e) {
  console.error(JSON.stringify({ error: e.message }))
  process.exit(1)
}
