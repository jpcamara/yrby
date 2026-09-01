// A collaborative spreadsheet. The shared state is a Y.Array of row Y.Maps,
// keyed by column id. A cell is not a scalar — it is its own Y.Map of
// { value, bold, fill }, so bolding a cell and typing in it are writes to
// different keys and both survive. The same property written twice is
// last-writer-wins. Sorting and column order come from TanStack Table and are
// deliberately NOT shared: they are this browser's view of the same rows. The
// server knows nothing about "cells" or "columns" either way.
import * as Y from "yjs"
import {
  constructTable,
  tableFeatures,
  rowSortingFeature,
  createSortedRowModel,
  sortFn_text,
  columnOrderingFeature,
} from "@tanstack/table-core"
import { storeReactivityBindings } from "@tanstack/table-core/store-reactivity-bindings"
import { connectRoom, uid, user, wireStoredPanel } from "./room.js"

const COLUMNS = [["item", "Item"], ["qty", "Qty"], ["owner", "Owner"], ["notes", "Notes"]]
const COL_IDS = COLUMNS.map((c) => c[0])
// Dark tints, not pastels: the fill is the cell's background and the text on
// it stays the page's light zinc, so the fills have to be darker than the
// text, not lighter.
const FILLS = [["", "none"], ["#4a3a12", "amber"], ["#143a26", "green"], ["#1c2f57", "blue"]]

const grid = document.getElementById("grid")
const toolbarEl = document.getElementById("toolbar")

const ydoc = new Y.Doc()
const rows = ydoc.getArray("rows")
const provider = connectRoom(ydoc, grid)

// A row is a Y.Map of column id -> cell Y.Map. Cells are created with the row so
// every column has one from the start; getCell backfills if a row arrives
// without one.
function newRow(values = {}) {
  const row = new Y.Map()
  row.set("id", uid())
  for (const id of COL_IDS) {
    const cell = new Y.Map()
    cell.set("value", values[id] ?? "")
    cell.set("bold", false)
    cell.set("fill", "")
    row.set(id, cell)
  }
  return row
}

function getCell(row, colId) {
  let cell = row.get(colId)
  if (!cell) {
    cell = new Y.Map()
    cell.set("value", "")
    row.set(colId, cell)
  }
  return cell
}

const addRow = () => rows.push([newRow()])
window.__yrby = { provider, ydoc, rows, user, newRow, getCell, addRow }

// --- TanStack Table: view state only -----------------------------------------
// The table is fed a plain snapshot of the Y.Array (rebuilt on every change) and
// owns sorting + column order. Neither is written back to the doc, so two
// browsers can sort the same rows differently while editing the same cells.
const features = tableFeatures({
  coreReactivityFeature: storeReactivityBindings(),
  rowSortingFeature,
  sortedRowModel: createSortedRowModel(),
  sortFns: { text: sortFn_text },
  columnOrderingFeature,
})
const columnDefs = COLUMNS.map(([id, header]) => ({ id, accessorKey: id, header, sortFn: "text" }))
const view = { sorting: [], columnOrder: [] }

// Snapshot the Y.Array as the table's `data`, plus a rowId -> row Y.Map index so
// a rendered cell can write back to the shared type it came from.
let yRows = new Map()
function snapshot() {
  yRows = new Map()
  return rows.toArray().map((row) => {
    const id = row.get("id")
    yRows.set(id, row)
    const record = { id }
    for (const colId of COL_IDS) record[colId] = row.get(colId)?.get("value") ?? ""
    return record
  })
}

const applyView = (key) => (updater) => {
  view[key] = typeof updater === "function" ? updater(view[key]) : updater
  table.setOptions((old) => ({ ...old, state: { ...old.state, ...view } }))
  render()
}

const table = constructTable({
  features,
  columns: columnDefs,
  data: snapshot(),
  getRowId: (record) => record.id,
  enableSortingRemoval: false,
  state: { ...view },
  onSortingChange: applyView("sorting"),
  onColumnOrderChange: applyView("columnOrder"),
})

const moveColumn = (colId, dir) => {
  const order = view.columnOrder.length ? [...view.columnOrder] : [...COL_IDS]
  const from = order.indexOf(colId)
  const to = from + dir
  if (to < 0 || to >= order.length) return
  order.splice(to, 0, ...order.splice(from, 1))
  table.setColumnOrder(order)
}

// --- Rendering ---------------------------------------------------------------
// The header is rebuilt every render; body <tr>s are pooled by row id and
// updated in place, so a remote edit elsewhere in the sheet doesn't destroy the
// input you are typing in.
const trs = new Map()
let activeCell = null // "<rowId>:<colId>" — the toolbar's target, kept after blur

function renderHeader() {
  const tr = document.createElement("tr")
  for (const header of table.getHeaderGroups()[0].headers) {
    const col = header.column
    const th = document.createElement("th")
    th.dataset.col = col.id
    const sorted = col.getIsSorted()
    const label = document.createElement("button")
    label.className = "sort"
    label.textContent = `${col.columnDef.header}${sorted === "asc" ? " ▲" : sorted === "desc" ? " ▼" : ""}`
    label.onclick = col.getToggleSortingHandler()
    th.appendChild(label)
    for (const [dir, glyph] of [["left", "◀"], ["right", "▶"]]) {
      const b = document.createElement("button")
      b.className = "movecol"
      b.dataset.move = dir
      b.textContent = glyph
      b.title = `move ${col.columnDef.header} ${dir}`
      b.onclick = () => moveColumn(col.id, dir === "left" ? -1 : 1)
      th.appendChild(b)
    }
    tr.appendChild(th)
  }
  grid.querySelector("thead").replaceChildren(tr)
}

function buildRow(rowId) {
  const tr = document.createElement("tr")
  tr.dataset.rowId = rowId
  for (const colId of COL_IDS) {
    const td = document.createElement("td")
    td.dataset.cell = `${rowId}:${colId}`
    const input = document.createElement("input")
    input.dataset.cell = td.dataset.cell
    // Spreadsheet semantics: the shared value is written on commit (Enter or
    // blur), not per keystroke. `change` fires for both.
    input.addEventListener("change", () => getCell(yRows.get(rowId), colId).set("value", input.value))
    // Enter commits and leaves the cell. preventDefault because a bare Enter in
    // a text input is an implicit form submission, which navigates the page.
    input.addEventListener("keydown", (e) => {
      if (e.key !== "Enter") return
      e.preventDefault()
      input.blur()
    })
    input.addEventListener("focus", () => {
      activeCell = td.dataset.cell
      provider.awareness.setLocalStateField("cell", td.dataset.cell)
      renderToolbar()
    })
    input.addEventListener("blur", () => provider.awareness.setLocalStateField("cell", null))
    td.appendChild(input)
    tr.appendChild(td)
  }
  return tr
}

// Moving a <tr> or <td> that contains the focused input blurs it, so every
// structural move is conditional and the caret is put back if one still lands
// on the cell you are typing in.
function render() {
  const focused = document.activeElement?.dataset?.cell
  const caret = focused ? [document.activeElement.selectionStart, document.activeElement.selectionEnd] : null

  renderHeader()
  const body = grid.querySelector("tbody")
  const order = table.getRowModel().rows.map((r) => r.original.id)
  for (const [rowId, tr] of trs) if (!order.includes(rowId)) { tr.remove(); trs.delete(rowId) }
  for (const rowId of order) if (!trs.has(rowId)) trs.set(rowId, buildRow(rowId))
  if ([...body.children].map((tr) => tr.dataset.rowId).join() !== order.join()) {
    for (const rowId of order) body.appendChild(trs.get(rowId))
  }

  // Column order is the table's, so the cells in each row follow the headers.
  const colOrder = table.getHeaderGroups()[0].headers.map((h) => h.column.id)
  for (const rowId of order) {
    const tr = trs.get(rowId)
    const row = yRows.get(rowId)
    const tds = new Map([...tr.children].map((td) => [td.dataset.cell.split(":")[1], td]))
    if ([...tds.keys()].join() !== colOrder.join()) {
      for (const colId of colOrder) tr.appendChild(tds.get(colId))
    }
    for (const colId of COL_IDS) {
      const cell = row.get(colId)
      const td = tds.get(colId)
      const input = td.firstChild
      const value = cell?.get("value") ?? ""
      if (input.value !== value && document.activeElement !== input) input.value = value
      input.style.fontWeight = cell?.get("bold") ? "700" : "400"
      td.style.background = cell?.get("fill") || ""
    }
  }

  if (focused && document.activeElement?.dataset?.cell !== focused) {
    const el = grid.querySelector(`input[data-cell="${focused}"]`)
    if (el) { el.focus(); el.setSelectionRange(caret[0], caret[1]) }
  }
  renderPeerCells()
  renderToolbar()
}
rows.observeDeep(() => {
  table.setOptions((old) => ({ ...old, data: snapshot() }))
  render()
})

// --- Toolbar: bold / fill on the selected cell --------------------------------
// These write single properties immediately — the counterpart to the deferred
// `value` commit.
function withActiveCell(fn) {
  if (!activeCell) return
  const [rowId, colId] = activeCell.split(":")
  const row = yRows.get(rowId)
  if (row) fn(getCell(row, colId))
}

function renderToolbar() {
  const [rowId, colId] = (activeCell || ":").split(":")
  const cell = yRows.get(rowId)?.get(colId)
  toolbarEl.querySelector("#bold").classList.toggle("on", !!cell?.get("bold"))
  toolbarEl.querySelector(".label").textContent = activeCell ? `cell ${colId}` : "no cell selected"
  for (const b of toolbarEl.querySelectorAll("[data-fill]")) {
    b.classList.toggle("on", !!cell && (cell.get("fill") || "") === b.dataset.fill)
  }
}

toolbarEl.innerHTML =
  `<button id="add-row" title="append a row">+ row</button>` +
  `<button id="bold" title="bold the selected cell">B</button>` +
  FILLS.map(([c, n]) => `<button data-fill="${c}" title="fill ${n}" style="background:${c || "transparent"}"></button>`).join("") +
  `<span class="label"></span>`
// mousedown default is what blurs the input, so the formatting buttons act on
// the cell you are in rather than the one you just left.
for (const b of toolbarEl.querySelectorAll("#bold,[data-fill]")) {
  b.addEventListener("mousedown", (e) => e.preventDefault())
}
toolbarEl.querySelector("#bold").onclick = () => withActiveCell((c) => c.set("bold", !c.get("bold")))
for (const b of toolbarEl.querySelectorAll("[data-fill]")) {
  b.onclick = () => withActiveCell((c) => c.set("fill", b.dataset.fill))
}
toolbarEl.querySelector("#add-row").onclick = addRow

// --- Presence -----------------------------------------------------------------
// The room bar renders the name chips. This adds the part only a sheet has: each
// peer publishes the cell it is focused in, and that cell gets their color and
// name in this browser, wherever their row happens to sit in *this* sort order.
function renderPeerCells() {
  for (const el of grid.querySelectorAll("td.peer")) {
    el.classList.remove("peer")
    el.style.boxShadow = ""
    el.querySelector(".peerlabel")?.remove()
  }
  const self = provider.awareness.clientID
  for (const [clientId, state] of provider.awareness.getStates()) {
    if (clientId === self || !state.cell || !state.user) continue
    const td = grid.querySelector(`td[data-cell="${state.cell}"]`)
    if (!td) continue
    td.classList.add("peer")
    td.style.boxShadow = `inset 0 0 0 2px ${state.user.color}`
    const tag = document.createElement("span")
    tag.className = "peerlabel"
    tag.style.background = state.user.color
    tag.textContent = state.user.name
    td.appendChild(tag)
  }
}
provider.awareness.on("update", renderPeerCells)

// Seed the starter rows only on the FIRST catch-up (whenSynced doesn't re-fire
// on reconnects, so a deliberately emptied sheet stays empty).
provider.whenSynced.then(() => {
  if (rows.length) return
  ydoc.transact(() => {
    for (const r of [
      { item: "Espresso machine", qty: "1", owner: "Ada", notes: "office" },
      { item: "Whiteboard markers", qty: "12", owner: "Grace", notes: "" },
      { item: "Standing desk", qty: "3", owner: "Linus", notes: "back order" },
    ]) rows.push([newRow(r)])
  })
})

render()
wireStoredPanel(ydoc)
provider.connect()
