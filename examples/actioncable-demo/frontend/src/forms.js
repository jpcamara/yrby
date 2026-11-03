// Opaque-state demo: a collaborative form.
// The shared state is a Y.Map keyed by field name. Each text field holds a
// nested Y.Text, so two people typing in the same field merge character by
// character, like the CodeMirror demo. The role is a plain value: a choice
// has no characters to merge, so the last pick wins. Same DocumentChannel
// either way.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import { bindTextField } from "./text_field.js"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS) }

const FIELDS = [
  { key: "name", label: "Full name", type: "text" },
  { key: "email", label: "Email", type: "email" },
  { key: "role", label: "Role", type: "select", options: ["", "Engineer", "Designer", "PM", "Other"] },
  { key: "notes", label: "Notes", type: "textarea" },
]
const isText = (f) => f.type !== "select"

const root = document.getElementById("form")
const statusEl = document.getElementById("status")
const presenceEl = document.getElementById("presence")
const documentId = root.dataset.documentId

const ydoc = new Y.Doc()
const form = ydoc.getMap("form")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
provider.awareness.setLocalStateField("user", user)
window.__yrb = { provider, ydoc, form, user }

const inputs = {}
for (const f of FIELDS) {
  const wrap = document.createElement("label")
  wrap.className = "field"
  wrap.appendChild(Object.assign(document.createElement("span"), { textContent: f.label }))
  let el
  if (f.type === "textarea") el = document.createElement("textarea")
  else if (f.type === "select") { el = document.createElement("select"); el.innerHTML = f.options.map((o) => `<option>${o}</option>`).join("") }
  else { el = document.createElement("input"); el.type = f.type }
  el.dataset.key = f.key
  // Text fields wait for their Y.Text, which exists once the form syncs.
  if (isText(f)) el.disabled = true
  else el.addEventListener("input", () => form.set(f.key, el.value))
  wrap.appendChild(el)
  root.appendChild(wrap)
  inputs[f.key] = el
}

// Each text field's binding, and the Y.Text it's bound to.
const bound = {}

function bindTextFields() {
  for (const f of FIELDS.filter(isText)) {
    const text = form.get(f.key)
    if (!(text instanceof Y.Text) || bound[f.key]?.text === text) continue
    bound[f.key]?.unbind()
    bound[f.key] = { text, unbind: bindTextField(inputs[f.key], text) }
    inputs[f.key].disabled = false
  }
}

// A field's Y.Text is created once, after the form has synced, so a page
// doesn't replace the one already in the document. Two pages that create
// the same field at the same moment both end up on whichever the map
// keeps, because bindTextFields rebinds when the map changes. An older
// document stored plain strings, and those become the starting text.
function createTextFields() {
  ydoc.transact(() => {
    for (const f of FIELDS.filter(isText)) {
      const value = form.get(f.key)
      if (!(value instanceof Y.Text)) form.set(f.key, new Y.Text(typeof value === "string" ? value : ""))
    }
  })
}

form.observe(() => {
  bindTextFields()
  for (const f of FIELDS.filter((f) => !isText(f))) {
    const v = form.get(f.key) ?? ""
    if (inputs[f.key].value !== v) inputs[f.key].value = v
  }
})

function renderPresence() {
  presenceEl.innerHTML = [...provider.awareness.getStates().values()].map((s) => s.user).filter(Boolean)
    .map((u) => `<span class="chip" style="background:${u.color}">${u.name}${u.name === user.name ? " (you)" : ""}</span>`).join("")
}
provider.awareness.on("update", renderPresence)

statusEl.textContent = `connecting as ${user.name}…`
provider.onStatusChange(({ status }) => {
  statusEl.textContent = status === "synced" ? `synced as ${user.name}` : `${status}…`
  if (status === "synced") {
    createTextFields()
    bindTextFields()
  }
})
renderPresence()
provider.connect()
