// Opaque-state demo: a collaborative whiteboard.
// Shared state is a Y.Map of shape records (id -> Y.Map{ x, y, text, color }).
// Double-click to add a note, drag to move (writes x/y), type to edit. Real
// canvas tools (tldraw, Excalidraw) keep their document as a record store and
// bind it to a Y.Map/Y.Array the same way — so this exact provider drops under
// them. yrby just syncs the Map.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS) }

const canvas = document.getElementById("canvas")
const statusEl = document.getElementById("status")
const presenceEl = document.getElementById("presence")
const documentId = canvas.dataset.documentId

const ydoc = new Y.Doc()
const shapes = ydoc.getMap("shapes")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
provider.awareness.setLocalStateField("user", user)

function addNote(x, y, text = "note") {
  const m = new Y.Map()
  m.set("x", x); m.set("y", y); m.set("text", text); m.set("color", user.color)
  shapes.set(crypto.randomUUID(), m)
}
window.__yrb = { provider, ydoc, shapes, user, addNote }

canvas.addEventListener("dblclick", (e) => {
  const r = canvas.getBoundingClientRect()
  addNote(Math.round(e.clientX - r.left - 60), Math.round(e.clientY - r.top - 24))
})

function makeDraggable(el, m) {
  el.addEventListener("pointerdown", (e) => {
    if (e.target.tagName === "TEXTAREA") return
    el.setPointerCapture(e.pointerId)
    const sx = e.clientX, sy = e.clientY, ox = m.get("x"), oy = m.get("y")
    const onMove = (ev) => ydoc.transact(() => { m.set("x", ox + ev.clientX - sx); m.set("y", oy + ev.clientY - sy) })
    const onUp = () => { el.removeEventListener("pointermove", onMove); el.removeEventListener("pointerup", onUp) }
    el.addEventListener("pointermove", onMove)
    el.addEventListener("pointerup", onUp)
  })
}

const els = new Map()
function render() {
  for (const [id, el] of els) if (!shapes.has(id)) { el.remove(); els.delete(id) }
  shapes.forEach((m, id) => {
    let el = els.get(id)
    if (!el) {
      el = document.createElement("div"); el.className = "note"; el.dataset.id = id
      const ta = document.createElement("textarea")
      ta.addEventListener("input", () => m.set("text", ta.value))
      el.appendChild(ta); el._ta = ta
      makeDraggable(el, m)
      canvas.appendChild(el); els.set(id, el)
    }
    el.style.left = `${m.get("x")}px`
    el.style.top = `${m.get("y")}px`
    el.style.background = m.get("color") || "#fde68a"
    const t = m.get("text") ?? ""
    if (el._ta.value !== t && document.activeElement !== el._ta) el._ta.value = t
  })
}
shapes.observeDeep(render)

function renderPresence() {
  presenceEl.innerHTML = [...provider.awareness.getStates().values()].map((s) => s.user).filter(Boolean)
    .map((u) => `<span class="chip" style="background:${u.color}">${u.name}${u.name === user.name ? " (you)" : ""}</span>`).join("")
}
provider.awareness.on("update", renderPresence)

statusEl.textContent = `connecting as ${user.name}…`
provider.onStatusChange(({ status }) => {
  statusEl.textContent = status === "synced" ? `synced as ${user.name}` : `${status}…`
})
// Seed the starter notes only on the FIRST catch-up (whenSynced doesn't
// re-fire on reconnects, so a deliberately cleared board stays cleared).
provider.whenSynced.then(() => {
  if (shapes.size === 0) { addNote(40, 40, "drag me"); addNote(240, 120, "double-click to add") }
})
render(); renderPresence()
provider.connect()
