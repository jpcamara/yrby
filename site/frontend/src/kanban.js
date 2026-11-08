// A collaborative kanban board. The shared state is a flat Y.Array of card
// Y.Maps ({ id, text, column }). Adding a card pushes a Y.Map, and deleting
// one splices the array. Moving a card is one map.set("column", ...), so two
// people moving different cards never conflict. The server doesn't know
// anything about cards or columns.
import * as Y from "yjs"
import { YrbyDocumentElement } from "yrby-client/element"
import { enterRoom, roomConsumer, setupRoomPage, uid } from "./room.js"

const COLUMNS = [["todo", "To Do"], ["doing", "Doing"], ["done", "Done"]]
const ORDER = COLUMNS.map((c) => c[0])

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]))

// Builds the board in the synced document's element. Returns the cards array
// and a function that stops observing it and removes the board.
function bind(target, ydoc) {
  const board = target.querySelector("#board")
  const cards = ydoc.getArray("cards")

  // Add the starter cards when the board is empty. yrby:synced fires after the
  // server's state is applied and doesn't fire again on reconnect, so a board
  // someone emptied stays empty.
  if (!cards.length) {
    ydoc.transact(() => {
      for (const [text, column] of [["Design the API", "todo"], ["Write the gem", "doing"], ["Ship it", "done"]]) {
        const m = new Y.Map()
        m.set("id", uid()); m.set("text", text); m.set("column", column)
        cards.push([m])
      }
    })
  }

  const lists = {}
  for (const [id, title] of COLUMNS) {
    const col = document.createElement("div")
    col.className = "col"
    col.innerHTML = `<h3>${title}</h3><div class="cards"></div>` +
      `<form class="add"><input placeholder="Add a card" aria-label="Add a card to ${title}"></form>`
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

  // The column under a point, by hit-testing the column boxes. Used on drop.
  const columnUnder = (x, y) =>
    ORDER.find((id) => {
      const r = lists[id].parentElement.getBoundingClientRect()
      return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
    })

  const clearDropTargets = () =>
    ORDER.forEach((id) => lists[id].parentElement.classList.remove("drop-target"))

  // The card this page is dragging. render() leaves it where the pointer is, so
  // someone else's change mid-drag doesn't drop it.
  let dragging = null

  // Drag a card between columns by its grip. The grip has touch-action: none so
  // a touch drag doesn't scroll the page. The card body still scrolls and
  // selects text normally.
  function makeCardDraggable(el, grip, m) {
    grip.addEventListener("pointerdown", (e) => {
      e.preventDefault()
      const rect = el.getBoundingClientRect()
      const offX = e.clientX - rect.left
      const offY = e.clientY - rect.top
      el.setPointerCapture(e.pointerId)
      dragging = el
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
        dragging = null
        el.classList.remove("dragging")
        el.style.cssText = ""
        const over = columnUnder(ev.clientX, ev.clientY)
        if (over && over !== m.get("column")) m.set("column", over)
        else render() // not moved here, but someone else may have moved it
      }
      el.addEventListener("pointermove", onMove)
      el.addEventListener("pointerup", onUp)
    })
  }

  function cardElement(m) {
    const el = document.createElement("div")
    el.className = "card"
    el.innerHTML = `<span class="grip" title="Drag to move" aria-hidden="true">⠿</span>` +
      `<span class="t">${esc(m.get("text"))}</span>` +
      `<button class="del" data-a="del" title="Delete card" aria-label="Delete card">×</button>`
    el.querySelector('[data-a="del"]').onclick = () => {
      const i = cards.toArray().indexOf(m)
      if (i >= 0) cards.delete(i, 1)
    }
    makeCardDraggable(el, el.querySelector(".grip"), m)
    return el
  }

  // One element per card, kept across renders. Each render puts the elements in
  // array order under their columns and removes the ones for deleted cards.
  const elements = new Map()

  function render() {
    const live = new Set(cards.toArray())
    for (const [m, el] of elements) if (!live.has(m)) { el.remove(); elements.delete(m) }
    for (const m of live) {
      if (!elements.has(m)) elements.set(m, cardElement(m))
      const el = elements.get(m)
      if (el === dragging) continue
      const list = lists[m.get("column")]
      if (list) list.appendChild(el)
      else el.remove()
    }
  }
  cards.observeDeep(render)
  render()

  return {
    cards,
    destroy() {
      cards.unobserveDeep(render)
      board.replaceChildren()
    },
  }
}

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const binding = bind(target, detail.doc)
  const leave = enterRoom(detail, { cards: binding.cards })
  detail.signal.addEventListener("abort", () => {
    leave()
    binding.destroy()
  }, { once: true })
})
