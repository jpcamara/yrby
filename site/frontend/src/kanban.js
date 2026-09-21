// A collaborative kanban board. The shared state is a flat Y.Array of card
// Y.Maps ({ id, text, column }). Adding a card pushes a Y.Map; moving a card is
// a single map.set("column", ...), so two people moving different cards never
// conflict; deleting splices the array. The server knows nothing about "cards"
// or "columns".
import * as Y from "yjs"
import { connectRoom, uid, user, wireStoredPanel } from "./room.js"

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
    m.set("id", uid()); m.set("text", text); m.set("column", id)
    cards.push([m])
    input.value = ""
  })
}

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]))
// The column under a point, by hit-testing the column boxes. Used on drop.
const columnUnder = (x, y) =>
  ORDER.find((id) => {
    const r = lists[id].parentElement.getBoundingClientRect()
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
  })

const clearDropTargets = () =>
  ORDER.forEach((id) => lists[id].parentElement.classList.remove("drop-target"))

// Drag a card between columns from its grip. Moving a card is one
// map.set("column", ...), so two people dragging different cards never
// conflict. The grip carries touch-action: none so a touch drag doesn't fight
// page scrolling; the card body still scrolls and selects.
function makeCardDraggable(el, grip, m) {
  grip.addEventListener("pointerdown", (e) => {
    e.preventDefault()
    const rect = el.getBoundingClientRect()
    const offX = e.clientX - rect.left
    const offY = e.clientY - rect.top
    el.setPointerCapture(e.pointerId)
    el.classList.add("dragging")
    el.style.width = `${rect.width}px`

    const onMove = (ev) => {
      el.style.left = `${ev.clientX - offX}px`
      el.style.top = `${ev.clientY - offY}px`
      const over = columnUnder(ev.clientX, ev.clientY)
      clearDropTargets()
      if (over) lists[over].parentElement.classList.add("drop-target")
    }
    const onUp = (ev) => {
      el.releasePointerCapture(e.pointerId)
      el.removeEventListener("pointermove", onMove)
      el.removeEventListener("pointerup", onUp)
      clearDropTargets()
      const over = columnUnder(ev.clientX, ev.clientY)
      if (over && over !== m.get("column")) m.set("column", over)
      else render() // dropped outside a column: snap back
    }
    el.addEventListener("pointermove", onMove)
    el.addEventListener("pointerup", onUp)
  })
}

function render() {
  for (const id of ORDER) lists[id].innerHTML = ""
  cards.toArray().forEach((m) => {
    const list = lists[m.get("column")]
    if (!list) return
    const el = document.createElement("div")
    el.className = "card"
    el.innerHTML = `<span class="grip" title="drag to move" aria-hidden="true">⠿</span>` +
      `<span class="t">${esc(m.get("text"))}</span>` +
      `<button class="del" data-a="del" title="delete">×</button>`
    el.querySelector('[data-a="del"]').onclick = () => {
      const i = cards.toArray().indexOf(m)
      if (i >= 0) cards.delete(i, 1)
    }
    makeCardDraggable(el, el.querySelector(".grip"), m)
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
      m.set("id", uid()); m.set("text", text); m.set("column", column)
      cards.push([m])
    }
  })
})

render()
wireStoredPanel(ydoc)
provider.connect()
