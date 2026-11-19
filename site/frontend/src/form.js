// A collaborative form. The shared state is a Y.Map named "form", keyed by
// field name. Each text field holds a nested Y.Text, so two people typing in
// the same field merge character by character, like the Code demo. The role
// is a plain value: a choice has no characters to merge, so the last pick
// wins. The server just syncs the Map.
import * as Y from "yjs"
import { YrbyDocumentElement } from "yrby-client/element"
import { enterRoom, roomConsumer, setupRoomPage } from "./room.js"
import { bindTextField } from "./text_field.js"

const FIELDS = [
  { key: "name", label: "Full name", type: "text" },
  { key: "email", label: "Email", type: "email" },
  { key: "role", label: "Role", type: "select", options: ["", "Engineer", "Designer", "PM", "Other"] },
  { key: "notes", label: "Notes", type: "textarea" },
]
const isText = (f) => f.type !== "select"

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

// Builds the fields and binds them to the synced document. Returns the shared
// map and a function that unbinds the fields and removes them.
function bind(target, ydoc) {
  const root = target.querySelector("#form")
  const form = ydoc.getMap("form")

  const inputs = {}
  for (const f of FIELDS) {
    const wrap = document.createElement("label")
    wrap.className = "field"
    wrap.appendChild(Object.assign(document.createElement("span"), { textContent: f.label }))
    let el
    if (f.type === "textarea") el = document.createElement("textarea")
    else if (f.type === "select") {
      el = document.createElement("select")
      el.append(...f.options.map((o) => new Option(o)))
    } else {
      el = document.createElement("input")
      el.type = f.type
    }
    el.dataset.key = f.key
    // Text fields wait for their Y.Text, created just below.
    if (isText(f)) el.disabled = true
    else el.addEventListener("change", () => form.set(f.key, el.value))
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
  // keeps, because bindTextFields rebinds when the map changes.
  function createTextFields() {
    ydoc.transact(() => {
      for (const f of FIELDS.filter(isText)) {
        if (!(form.get(f.key) instanceof Y.Text)) form.set(f.key, new Y.Text())
      }
    })
  }

  function render() {
    bindTextFields()
    for (const f of FIELDS.filter((f) => !isText(f))) {
      const v = form.get(f.key) ?? ""
      if (inputs[f.key].value !== v) inputs[f.key].value = v
    }
  }
  form.observe(render)

  createTextFields()
  render()

  return {
    form,
    destroy() {
      form.unobserve(render)
      for (const b of Object.values(bound)) b.unbind()
      root.replaceChildren()
    },
  }
}

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const binding = bind(target, detail.doc)
  const leave = enterRoom(detail, { form: binding.form })
  detail.signal.addEventListener("abort", () => {
    leave()
    binding.destroy()
  }, { once: true })
})
