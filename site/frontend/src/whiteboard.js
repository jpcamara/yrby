// A collaborative whiteboard. The shared state is a Y.Map of shapes
// (id -> Y.Map{ x, y, text, color }). Double-click to add a note, drag to move
// it (this writes x and y), and type to edit. Canvas tools like tldraw and
// Excalidraw store their document as records and bind them to a Y.Map the
// same way, so this provider works with them too. The server just syncs the
// Map.
import * as Y from "yjs"
import { YrbyDocumentElement } from "yrby-client/element"
import { enterRoom, roomConsumer, setupRoomPage, uid, user } from "./room.js"

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

// Builds the canvas in the synced document's element. Returns the shapes map,
// addNote, and a function that stops observing the map and clears the canvas.
function bind(target, ydoc) {
  const canvas = target.querySelector("#canvas")
  const shapes = ydoc.getMap("shapes")

  function addNote(x, y, text = "New note") {
    const m = new Y.Map()
    m.set("x", x); m.set("y", y); m.set("text", text); m.set("color", user.color)
    shapes.set(uid(), m)
  }

  const onDoubleClick = (e) => {
    const r = canvas.getBoundingClientRect()
    addNote(Math.round(e.clientX - r.left - 60), Math.round(e.clientY - r.top - 24))
  }
  canvas.addEventListener("dblclick", onDoubleClick)

  function makeDraggable(el, m) {
    el.addEventListener("pointerdown", (e) => {
      if (e.target.tagName === "TEXTAREA") return
      el.setPointerCapture(e.pointerId)
      const sx = e.clientX, sy = e.clientY, ox = m.get("x"), oy = m.get("y")
      // One transaction per pointer move, so x and y go out in one update.
      const onMove = (ev) => ydoc.transact(() => {
        m.set("x", ox + ev.clientX - sx)
        m.set("y", oy + ev.clientY - sy)
      })
      const onUp = () => {
        el.removeEventListener("pointermove", onMove)
        el.removeEventListener("pointerup", onUp)
      }
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
        el = document.createElement("div")
        el.className = "note"
        el.dataset.id = id
        const grip = document.createElement("div")
        grip.className = "note-grip"
        el.appendChild(grip)
        const ta = document.createElement("textarea")
        ta.addEventListener("input", () => m.set("text", ta.value))
        el.appendChild(ta)
        el._ta = ta
        makeDraggable(el, m)
        canvas.appendChild(el)
        els.set(id, el)
      }
      el.style.left = `${m.get("x")}px`
      el.style.top = `${m.get("y")}px`
      el.style.background = m.get("color") || "#fde68a"
      const t = m.get("text") ?? ""
      if (el._ta.value !== t && document.activeElement !== el._ta) el._ta.value = t
    })
  }
  shapes.observeDeep(render)

  // Add the starter notes when the board is empty. yrby:synced fires after the
  // server's state is applied and doesn't fire again on reconnect, so a board
  // someone cleared stays clear.
  if (shapes.size === 0) {
    addNote(40, 40, "Drag me")
    addNote(240, 120, "Double-click to add a note")
  }

  render()

  return {
    shapes,
    addNote,
    destroy() {
      shapes.unobserveDeep(render)
      canvas.removeEventListener("dblclick", onDoubleClick)
      canvas.replaceChildren()
    },
  }
}

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const binding = bind(target, detail.doc)
  const leave = enterRoom(detail, { shapes: binding.shapes, addNote: binding.addNote })
  detail.signal.addEventListener("abort", () => {
    leave()
    binding.destroy()
  }, { once: true })
})
