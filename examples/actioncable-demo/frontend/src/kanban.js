// Opaque-state demo: a collaborative kanban board.
// Shared state is a flat Y.Array of card Y.Maps ({ id, text, column }). Adding a
// card pushes a Y.Map; moving a card is a single map.set("column", ...) so two
// people moving different cards never conflict; deleting splices the array.
// Same DocumentChannel — yrby knows nothing about "cards" or "columns".
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS) }

const COLUMNS = [["todo", "To Do"], ["doing", "Doing"], ["done", "Done"]]
const ORDER = COLUMNS.map((c) => c[0])

const board = document.getElementById("board")
const statusEl = document.getElementById("status")
const presenceEl = document.getElementById("presence")
const documentId = board.dataset.documentId

const ydoc = new Y.Doc()
const cards = ydoc.getArray("cards")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
provider.awareness.setLocalStateField("user", user)
window.__yrb = { provider, ydoc, cards, user }

const lists = {}
for (const [id, title] of COLUMNS) {
  const col = document.createElement("div")
  col.className = "col"
  col.innerHTML = `<h3>${title}</h3><div class="cards"></div><form class="add"><input placeholder="+ add card" aria-label="add to ${title}"></form>`
  board.appendChild(col)
  lists[id] = col.querySelector(".cards")
  col.querySelector("form").addEventListener("submit", (e) => {
    e.preventDefault()
    const inp = e.target.querySelector("input")
    const t = inp.value.trim()
    if (!t) return
    const m = new Y.Map()
    m.set("id", crypto.randomUUID()); m.set("text", t); m.set("column", id)
    cards.push([m])
    inp.value = ""
  })
}

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]))
const move = (m, dir) => { const n = ORDER[ORDER.indexOf(m.get("column")) + dir]; if (n) m.set("column", n) }

function render() {
  for (const id of ORDER) lists[id].innerHTML = ""
  cards.toArray().forEach((m) => {
    const list = lists[m.get("column")]
    if (!list) return
    const el = document.createElement("div")
    el.className = "card"
    el.innerHTML = `<span class="t">${esc(m.get("text"))}</span><span class="ctl">` +
      `<button data-a="left" title="move left">←</button><button data-a="right" title="move right">→</button>` +
      `<button data-a="del" title="delete">×</button></span>`
    el.querySelector('[data-a="left"]').onclick = () => move(m, -1)
    el.querySelector('[data-a="right"]').onclick = () => move(m, 1)
    el.querySelector('[data-a="del"]').onclick = () => { const i = cards.toArray().indexOf(m); if (i >= 0) cards.delete(i, 1) }
    list.appendChild(el)
  })
}
cards.observeDeep(render)

function renderPresence() {
  presenceEl.innerHTML = [...provider.awareness.getStates().values()].map((s) => s.user).filter(Boolean)
    .map((u) => `<span class="chip" style="background:${u.color}">${u.name}${u.name === user.name ? " (you)" : ""}</span>`).join("")
}
provider.awareness.on("update", renderPresence)

statusEl.textContent = `connecting as ${user.name}…`
provider.onStatusChange(({ status }) => {
  statusEl.textContent = status === "synced" ? `synced as ${user.name}` : `${status}…`
})
// Seed the starter cards only on the FIRST catch-up (whenSynced doesn't
// re-fire on reconnects, so a deliberately emptied board stays empty).
provider.whenSynced.then(() => {
  if (cards.length) return
  ydoc.transact(() => {
    for (const [t, c] of [["Design the API", "todo"], ["Write the gem", "doing"], ["Ship it 🚀", "done"]]) {
      const m = new Y.Map(); m.set("id", crypto.randomUUID()); m.set("text", t); m.set("column", c); cards.push([m])
    }
  })
})
render(); renderPresence()
provider.connect()
