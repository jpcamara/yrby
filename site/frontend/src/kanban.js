// A collaborative kanban board. The shared state is a flat Y.Array of card
// Y.Maps ({ id, text, column }). Adding a card pushes a Y.Map; moving a card is
// a single map.set("column", ...), so two people moving different cards never
// conflict; deleting splices the array. The server knows nothing about "cards"
// or "columns".
import * as Y from "yjs"
import { connectRoom, user } from "./room.js"

const COLUMNS = [["todo", "To Do"], ["doing", "Doing"], ["done", "Done"]]
const ORDER = COLUMNS.map((c) => c[0])

const board = document.getElementById("board")
const ydoc = new Y.Doc()
const cards = ydoc.getArray("cards")
const provider = connectRoom(ydoc, board)

window.__yrby = { provider, ydoc, cards, user }

const lists = {}
for (const [id, title] of COLUMNS) {
  const col = document.createElement("div")
  col.className = "col"
  col.innerHTML = `<h3>${title}</h3><div class="cards"></div>` +
    `<form class="add"><input placeholder="+ add card" aria-label="add to ${title}"></form>`
  board.appendChild(col)
  lists[id] = col.querySelector(".cards")
  col.querySelector("form").addEventListener("submit", (e) => {
    e.preventDefault()
    const input = e.target.querySelector("input")
    const text = input.value.trim()
    if (!text) return
    const m = new Y.Map()
    m.set("id", crypto.randomUUID()); m.set("text", text); m.set("column", id)
    cards.push([m])
    input.value = ""
  })
}

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]))
const move = (m, dir) => {
  const next = ORDER[ORDER.indexOf(m.get("column")) + dir]
  if (next) m.set("column", next)
}

function render() {
  for (const id of ORDER) lists[id].innerHTML = ""
  cards.toArray().forEach((m) => {
    const list = lists[m.get("column")]
    if (!list) return
    const el = document.createElement("div")
    el.className = "card"
    el.innerHTML = `<span class="t">${esc(m.get("text"))}</span><span class="ctl">` +
      `<button data-a="left" title="move left">←</button>` +
      `<button data-a="right" title="move right">→</button>` +
      `<button data-a="del" title="delete">×</button></span>`
    el.querySelector('[data-a="left"]').onclick = () => move(m, -1)
    el.querySelector('[data-a="right"]').onclick = () => move(m, 1)
    el.querySelector('[data-a="del"]').onclick = () => {
      const i = cards.toArray().indexOf(m)
      if (i >= 0) cards.delete(i, 1)
    }
    list.appendChild(el)
  })
}
cards.observeDeep(render)

// Seed the starter cards only on the FIRST catch-up (whenSynced doesn't re-fire
// on reconnects, so a deliberately emptied board stays empty).
provider.whenSynced.then(() => {
  if (cards.length) return
  ydoc.transact(() => {
    for (const [text, column] of [["Design the API", "todo"], ["Write the gem", "doing"], ["Ship it", "done"]]) {
      const m = new Y.Map()
      m.set("id", crypto.randomUUID()); m.set("text", text); m.set("column", column)
      cards.push([m])
    }
  })
})

render()
provider.connect()
