// node --test text_field_test.mjs
// Two documents that exchange updates, each with a field bound to the same
// Y.Text, stand in for two people on the form page.
import { test } from "node:test"
import assert from "node:assert/strict"
import * as Y from "yjs"
import { bindTextField, moved } from "./src/text_field.js"

class Field {
  value = ""
  selectionStart = 0
  selectionEnd = 0
  selectionDirection = "none"
  #listeners = []
  addEventListener(_type, fn) { this.#listeners.push(fn) }
  removeEventListener(_type, fn) { this.#listeners = this.#listeners.filter((l) => l !== fn) }
  setSelectionRange(start, end, direction) { Object.assign(this, { selectionStart: start, selectionEnd: end, selectionDirection: direction }) }
  type(at, removing, adding) {
    this.value = this.value.slice(0, at) + adding + this.value.slice(at + removing)
    this.setSelectionRange(at + adding.length, at + adding.length, "none")
    this.#listeners.forEach((l) => l())
  }
}

// Two people on one form whose "name" field already holds a Y.Text.
function twoPeople(initial = "") {
  const a = new Y.Doc()
  a.transact(() => a.getMap("form").set("name", new Y.Text(initial)))
  const b = new Y.Doc()
  Y.applyUpdate(b, Y.encodeStateAsUpdate(a))
  return [a, b].map((doc) => {
    const text = doc.getMap("form").get("name")
    const field = new Field()
    bindTextField(field, text)
    return { doc, text, field }
  })
}

// Delivers each side's changes to the other.
function exchange(a, b) {
  const fromA = Y.encodeStateAsUpdate(a.doc, Y.encodeStateVector(b.doc))
  const fromB = Y.encodeStateAsUpdate(b.doc, Y.encodeStateVector(a.doc))
  Y.applyUpdate(b.doc, fromA)
  Y.applyUpdate(a.doc, fromB)
}

test("binding shows the text already there", () => {
  const [a, b] = twoPeople("Ada")
  assert.equal(a.field.value, "Ada")
  assert.equal(b.field.value, "Ada")
})

test("two people typing in one field at once both keep their edit", () => {
  const [a, b] = twoPeople("Ada")
  a.field.type(3, 0, " Lovelace")
  b.field.type(0, 0, "Dr. ")
  exchange(a, b)
  assert.equal(a.text.toString(), "Dr. Ada Lovelace")
  assert.equal(b.text.toString(), "Dr. Ada Lovelace")
  assert.equal(a.field.value, "Dr. Ada Lovelace")
  assert.equal(b.field.value, "Dr. Ada Lovelace")
})

test("a replaced selection turns into one delete and one insert", () => {
  const [a, b] = twoPeople("Grace Hopper")
  a.field.type(0, 5, "Admiral")
  exchange(a, b)
  assert.equal(b.field.value, "Admiral Hopper")
})

test("a remote edit before the caret moves it, and one after it doesn't", () => {
  const [a, b] = twoPeople("Ada")
  b.field.setSelectionRange(3, 3, "none")
  a.field.type(0, 0, "Dr. ")
  exchange(a, b)
  assert.equal(b.field.selectionStart, 7)
  a.field.type(7, 0, "!")
  exchange(a, b)
  assert.equal(b.field.selectionStart, 7)
  a.field.type(0, 4, "")
  exchange(a, b)
  assert.equal(b.field.value, "Ada!")
  assert.equal(b.field.selectionStart, 3)
})

test("emoji count as the DOM counts them", () => {
  const [a, b] = twoPeople("")
  a.field.type(0, 0, "hi 😀")
  b.field.type(0, 0, "→ ")
  exchange(a, b)
  assert.equal(a.field.value, b.field.value)
  assert.ok(["hi 😀→ ", "→ hi 😀"].includes(a.field.value))
})

test("moved shifts by deletions that straddle the caret only up to it", () => {
  assert.equal(moved(5, [{ retain: 3 }, { delete: 4 }]), 3)
  assert.equal(moved(5, [{ retain: 5 }, { insert: "x" }]), 5)
  assert.equal(moved(5, [{ insert: "ab" }]), 7)
})

test("an unbound field stops following the text", () => {
  const [a] = twoPeople("Ada")
  const other = new Field()
  const unbind = bindTextField(other, a.text)
  unbind()
  a.field.type(3, 0, "!")
  assert.equal(a.text.toString(), "Ada!")
  assert.equal(other.value, "Ada")
})
