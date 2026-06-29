// Opaque-state demo: a collaborative form.
// Shared state is a Y.Map keyed by field name. Each input writes form.set(key,
// value); a remote change updates the input (skipping the field you're focused
// in, so your typing isn't clobbered). Field values are last-writer-wins per
// field (Y.Map) — to character-merge WITHIN a field you'd use a Y.Text, exactly
// like the CodeMirror demo. Same DocumentChannel either way.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

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
  el.addEventListener("input", () => form.set(f.key, el.value))
  wrap.appendChild(el)
  root.appendChild(wrap)
  inputs[f.key] = el
}

form.observe(() => {
  for (const f of FIELDS) {
    const v = form.get(f.key) ?? ""
    const el = inputs[f.key]
    if (el.value !== v && document.activeElement !== el) el.value = v
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
})
renderPresence()
provider.connect()
