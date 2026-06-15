// Helpers for reading the server's view of a document.
//
// /docs/:id/content returns the raw CRDT state as { state: "<base64>" } (the
// base64 of encodeStateAsUpdate). Apply it to a fresh Y.Doc to see exactly what
// the server holds. (The gem no longer extracts ProseMirror JSON server-side;
// decoding the CRDT client-side is the equivalent read.)
import * as Y from "yjs"

// Fetch the server's state for a room. Returns { status, doc } where doc is a
// fresh Y.Doc loaded from the server's state, or null if the doc isn't found.
export async function serverDoc(baseUrl, room) {
  const res = await fetch(`${baseUrl}/docs/${room}/content`)
  if (res.status !== 200) return { status: res.status, doc: null }
  const { state } = await res.json()
  const doc = new Y.Doc()
  Y.applyUpdate(doc, new Uint8Array(Buffer.from(state, "base64")))
  return { status: res.status, doc }
}

// Plain text content of the server's document (XML tags stripped).
export async function serverText(baseUrl, room) {
  const { doc } = await serverDoc(baseUrl, room)
  if (!doc) return ""
  return doc.getXmlFragment("default").toString().replace(/<[^>]*>/g, "")
}
