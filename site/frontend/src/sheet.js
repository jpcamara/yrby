// A room's agent sheet: a spreadsheet with tabs and formulas that people edit
// together, where each person can invite their own agent and ask it to fill
// cells. app/agents/sheet_agent.rb documents the shared document's shape and
// an ask's fields.
//
// Only what people type is shared. Every browser computes values from the
// inputs with its own formula engine (formula.js), so the server never
// evaluates a formula.
//
// - Selection, editing, the formula bar, copy and paste, and formatting work
//   on the active tab. Undo and redo cover this browser's own edits.
// - Each person's selected cell, and each agent's, is outlined in their color
//   with a name tag, through awareness.
// - An ask goes into the "asks" map, so everyone sees it in the side panel.
//   The asker's agent claims it and writes cells; its card can undo every
//   cell the ask wrote.
import "./sheet.css"
import * as Y from "yjs"
import { YrbyDocumentElement } from "yrby-client/element"
import { roomConsumer, setupRoomPage, uid, user } from "./room.js"
import { Workbook, cellName, colName, display, isError, parseCell, renameTab } from "./formula.js"
import { TABS as SEED_TABS, TITLE as SEED_TITLE } from "./sheet_seed.js"

// --- who you are -------------------------------------------------------------

// As on the shared page (space.js): the same id, name, and color across
// reloads of this tab, and a second window is a second person.
const me = (() => {
  try {
    const saved = JSON.parse(sessionStorage.getItem("yrby-sheet-person"))
    if (saved?.id) return saved
  } catch { /* storage blocked or empty */ }
  const fresh = { id: uid(), name: user.name, color: user.color }
  try { sessionStorage.setItem("yrby-sheet-person", JSON.stringify(fresh)) } catch { /* fine */ }
  return fresh
})()

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

const FILLS = [["", "No fill"], ["#ececec", "Gray"], ["#dbe7fb", "Blue"], ["#d7f0dd", "Green"], ["#fbe8c4", "Amber"], ["#f9dbe0", "Rose"]]
const CELL_FIELDS = ["input", "format", "bold", "fill", "color", "by", "ask"]
const MIN_ROWS = 30
const MIN_COLS = 10
const DEFAULT_WIDTH = 110
const OPEN = new Set(["asked", "working"])
const LOCAL = { local: true } // the origin of this browser's own edits, which undo tracks

const $ = (id) => document.getElementById(id)

// --- inviting your agent ---------------------------------------------------

const inviteButton = $("invite-agent")
const CANT_COME = {
  busy: ["Every agent seat is taken right now. Try again in a few minutes.", "every agent seat is taken right now"],
  limited: ["You've invited an agent a lot this hour. Try again later.", "you've invited an agent a lot this hour"],
  refused: ["Your agent couldn't join this sheet.", "it couldn't join this sheet"],
  offline: ["Couldn't reach the server.", "the server couldn't be reached"],
}

// Asks the server to start your agent on this sheet. Returns null once it's
// coming, or why it can't (a CANT_COME key).
async function inviteAgent() {
  try {
    const query = new URLSearchParams({ owner: me.id, name: me.name, color: me.color })
    const response = await fetch(`${inviteButton.dataset.url}?${query}`, { method: "POST" })
    const json = response.headers.get("content-type")?.includes("json") ? await response.json() : {}
    if (json.status === "joining" || json.status === "here") return null
    return json.status === "busy" ? "busy" : response.status === 429 ? "limited" : "refused"
  } catch {
    return "offline"
  }
}

inviteButton.addEventListener("click", async () => {
  inviteButton.disabled = true
  const problem = await inviteAgent()
  if (problem) toast(CANT_COME[problem][0])
  else inviteButton.querySelector("span").textContent = "Your agent is joining…"
  inviteButton.disabled = false
})

$("share").addEventListener("click", async () => {
  const label = $("share").querySelector("span")
  try {
    await navigator.clipboard.writeText(location.href)
    label.textContent = "Link copied"
  } catch {
    label.textContent = "Copy the address bar"
  }
  setTimeout(() => { label.textContent = "Share" }, 1800)
})

function toast(text) {
  const node = $("toast")
  node.textContent = text
  node.hidden = false
  clearTimeout(toast.timer)
  toast.timer = setTimeout(() => { node.hidden = true }, 4000)
}

// --- the session -------------------------------------------------------------

document.addEventListener("yrby:synced", ({ detail }) => {
  const sheet = new Sheet(detail)
  window.__yrby = { ydoc: detail.doc, provider: detail.provider, me, sheet }
  detail.signal.addEventListener("abort", () => sheet.stop(), { once: true })
})

class Sheet {
  constructor({ doc, provider, lease }) {
    this.doc = doc
    this.provider = provider
    this.lease = lease
    this.tabs = doc.getArray("tabs")
    this.sheets = doc.getMap("sheets")
    this.asks = doc.getMap("asks")
    this.meta = doc.getMap("meta")
    this.stops = []
    this.seed()

    this.active = this.tabIds()[0]
    this.anchor = { col: 0, row: 0 }
    this.focus = { col: 0, row: 0 }
    this.editing = null // { input, original } while a cell editor is open
    this.dims = null

    this.workbook = new Workbook({
      tabs: () => this.tabIds().map((id) => ({ id, name: this.tabName(id) })),
      input: (tab, ref) => this.cell(tab, ref)?.get("input"),
      extent: (tab) => this.extent(tab),
    })
    // Each commit is its own step, however quickly the next one follows.
    this.undo = new Y.UndoManager([this.tabs, this.sheets, this.meta], { trackedOrigins: new Set([LOCAL]), captureTimeout: 0 })

    this.grid = $("grid")
    this.scroll = $("grid-scroll")
    this.overlays = $("overlays")
    this.formula = $("formula")
    this.nameBox = $("name-box")

    this.listen(this.sheets, "observeDeep", (events) => this.sheetsChanged(events))
    this.listen(this.tabs, "observe", () => { this.workbook.invalidateAll(); this.render() })
    this.listen(this.asks, "observeDeep", () => this.renderAsks())
    this.listen(this.meta, "observe", () => this.renderTitle())
    const onAwareness = () => { this.renderPeers(); this.renderAvatars(); this.renderAsks() }
    provider.awareness.on("change", onAwareness)
    this.stops.push(() => provider.awareness.off("change", onAwareness))
    const onStatus = ({ status }) => {
      $("status").dataset.state = status
      $("status").textContent = status === "synced" ? "Saved" : status === "disconnected" ? "Offline" : "Connecting…"
      if (status !== "disconnected" && !provider.awareness.getLocalState()) this.join()
    }
    this.stops.push(provider.onStatusChange(onStatus))
    onStatus({ status: provider.status })
    const tick = setInterval(() => this.tickTimers(), 1000)
    this.stops.push(() => clearInterval(tick))

    this.join()
    this.wireGrid()
    this.wireToolbar()
    this.wireAskForm()
    this.render()
    this.renderAsks()
  }

  listen(type, how, fn) {
    type[how](fn)
    this.stops.push(() => type[how === "observe" ? "unobserve" : "unobserveDeep"](fn))
  }

  stop() {
    this.stops.forEach((stop) => stop())
    this.undo.destroy()
  }

  // A new room gets the seed tabs. yrby:synced fires once the server's state
  // is in, so a room someone already filled is left alone.
  seed() {
    if (this.tabs.length) return
    this.doc.transact(() => {
      for (const { id, name, cells, widths } of SEED_TABS) {
        this.sheets.set(id, tabMap(name, cells(), widths))
      }
      this.tabs.push(SEED_TABS.map((t) => t.id))
      this.meta.set("title", SEED_TITLE)
    }, "seed")
  }

  // --- reading the document ---

  // Tab ids in order, once each: two browsers that seed at once both push
  // the seed ids.
  tabIds() { return [...new Set(this.tabs.toArray())].filter((id) => this.sheets.get(id)) }
  tabName(id) { return this.sheets.get(id)?.get("name") ?? "Sheet" }
  cells(tab = this.active) { return this.sheets.get(tab)?.get("cells") }
  cell(tab, ref) { return this.cells(tab)?.get(ref) }
  value(tab, ref) { return this.workbook.value(tab, ref) }

  extent(tab) {
    let rows = 0
    let cols = 0
    for (const ref of this.cells(tab)?.keys() ?? []) {
      const p = parseCell(ref)
      if (!p) continue
      rows = Math.max(rows, p.row + 1)
      cols = Math.max(cols, p.col + 1)
    }
    return { rows, cols }
  }

  // The values that depend on what changed are computed again; nothing else.
  sheetsChanged(events) {
    let all = false
    for (const event of events) {
      const path = event.path
      if (path.length === 0 || (path.length === 1 && event.keysChanged.has("name"))) all = true
      else if (path.length === 2 && path[1] === "cells") {
        for (const ref of event.keysChanged) this.workbook.invalidate(path[0], ref)
      } else if (path.length === 3 && path[1] === "cells" && event.keysChanged.has("input")) {
        this.workbook.invalidate(path[0], path[2])
      }
    }
    if (all) this.workbook.invalidateAll()
    this.render()
  }

  // --- presence ---

  join() {
    this.lease.setPresence({ user: { name: me.name, color: me.color }, person: me.id, cell: this.presenceCell() })
  }

  presenceCell() { return this.active ? { tab: this.active, ref: cellName(this.focus.col, this.focus.row) } : null }

  peers() {
    return [...this.provider.awareness.getStates().entries()]
      .filter(([id, s]) => id !== this.provider.awareness.clientID && s?.user?.name)
      .map(([id, s]) => ({ id, ...s }))
  }

  myAgent() { return this.peers().find((p) => p.agent?.owner === me.id) }

  // --- writing ---

  // Sets fields on one cell, in a transaction undo tracks. An empty input
  // with no formatting removes the cell.
  write(tab, ref, fields) {
    const cells = this.cells(tab)
    if (!cells) return
    let cell = cells.get(ref)
    if (!cell) {
      if (fields.input === "" && Object.keys(fields).length === 1) return
      cell = new Y.Map()
      cells.set(ref, cell)
    }
    for (const [key, value] of Object.entries(fields)) {
      if (value === undefined || value === null || value === "" || value === false) cell.delete(key)
      else cell.set(key, value)
    }
    if ("input" in fields) {
      cell.set("by", me.name)
      cell.delete("ask")
    }
    if (![...cell.keys()].some((k) => ["input", "format", "bold", "fill", "color"].includes(k))) cells.delete(ref)
  }

  transact(fn) { this.doc.transact(fn, LOCAL) }

  // Every cell in the selected range.
  *selected() {
    const [c1, c2] = [this.anchor.col, this.focus.col].sort((a, b) => a - b)
    const [r1, r2] = [this.anchor.row, this.focus.row].sort((a, b) => a - b)
    for (let r = r1; r <= r2; r++) for (let c = c1; c <= c2; c++) yield cellName(c, r)
  }

  setInput(ref, input) { this.transact(() => this.write(this.active, ref, { input })) }

  format(fields) {
    this.transact(() => { for (const ref of this.selected()) this.write(this.active, ref, fields) })
  }

  // --- the grid ---

  render() {
    if (this.pending) return
    this.pending = requestAnimationFrame(() => {
      this.pending = null
      if (!this.sheets.get(this.active)) this.active = this.tabIds()[0]
      this.renderTabs()
      this.renderGrid()
      this.renderSelection()
      this.renderPeers()
      this.renderAvatars()
      this.renderTitle()
    })
  }

  renderGrid() {
    const { rows, cols } = this.extent(this.active)
    const widths = this.sheets.get(this.active)?.get("widths")
    const widthKey = JSON.stringify(widths?.toJSON() ?? {})
    const same = this.dims?.tab === this.active
    // The grid only grows while you stay on a tab, so cells don't jump.
    const want = {
      tab: this.active, widthKey,
      rows: Math.max(MIN_ROWS, rows + 5, same ? this.dims.rows : 0),
      cols: Math.max(MIN_COLS, cols + 2, same ? this.dims.cols : 0),
    }
    if (!same || want.rows > this.dims.rows || want.cols > this.dims.cols || widthKey !== this.dims.widthKey) {
      this.build(want.rows, want.cols, widths)
      this.dims = want
    }
    for (const [ref, td] of this.tdByRef.map) {
      const cell = this.cells()?.get(ref)
      const value = cell ? this.value(this.active, ref) : null
      const text = display(value, cell?.get("format"))
      if (td.textContent !== text) td.textContent = text
      td.className = [
        typeof value === "number" ? "num" : "",
        isError(value) ? "err" : "",
        cell?.get("bold") ? "bold" : "",
        cell?.get("ask") ? "by-agent" : "",
      ].filter(Boolean).join(" ")
      const fill = cell?.get("fill") ?? ""
      if (td.style.background !== fill) td.style.background = fill
    }
    if (!this.editing) this.syncFormulaBar()
  }

  // Builds an empty table of `rows` by `cols`.
  build(rows, cols, widths) {
    const colgroup = this.grid.querySelector("colgroup")
    colgroup.replaceChildren(el("col", { style: "width:44px" }),
      ...Array.from({ length: cols }, (_, c) => el("col", { style: `width:${widths?.get(colName(c)) ?? DEFAULT_WIDTH}px` })))
    const head = el("tr", {}, [el("th", { className: "corner" })])
    for (let c = 0; c < cols; c++) {
      const th = el("th", { className: "col-head" }, [colName(c)])
      const grip = el("span", { className: "col-grip" })
      grip.addEventListener("mousedown", (event) => this.resizeColumn(event, c))
      th.append(grip)
      head.append(th)
    }
    this.grid.querySelector("thead").replaceChildren(head)
    const map = new Map()
    const body = []
    for (let r = 0; r < rows; r++) {
      const tr = el("tr", {}, [el("th", { className: "row-head" }, [String(r + 1)])])
      for (let c = 0; c < cols; c++) {
        const td = el("td")
        td.dataset.ref = cellName(c, r)
        map.set(td.dataset.ref, td)
        tr.append(td)
      }
      body.push(tr)
    }
    this.grid.querySelector("tbody").replaceChildren(...body)
    this.tdByRef = { map, rows, cols }
  }

  resizeColumn(event, c) {
    event.preventDefault()
    event.stopPropagation()
    const col = this.grid.querySelectorAll("col")[c + 1]
    const startX = event.clientX
    const start = col.getBoundingClientRect().width || DEFAULT_WIDTH
    const move = (e) => {
      col.style.width = `${Math.max(40, Math.round(start + e.clientX - startX))}px`
      this.renderSelection()
      this.renderPeers()
    }
    const up = (e) => {
      removeEventListener("mousemove", move)
      removeEventListener("mouseup", up)
      const width = Math.max(40, Math.round(start + e.clientX - startX))
      this.transact(() => this.sheets.get(this.active)?.get("widths")?.set(colName(c), width))
    }
    addEventListener("mousemove", move)
    addEventListener("mouseup", up)
  }

  td(ref) { return this.tdByRef?.map.get(ref) }

  // A box over the cells from `a` to `b`, in the grid's coordinates.
  box(a, b = a) {
    const first = this.td(cellName(Math.min(a.col, b.col), Math.min(a.row, b.row)))
    const last = this.td(cellName(Math.max(a.col, b.col), Math.max(a.row, b.row)))
    if (!first || !last) return null
    return {
      left: first.offsetLeft, top: first.offsetTop,
      width: last.offsetLeft + last.offsetWidth - first.offsetLeft, height: last.offsetTop + last.offsetHeight - first.offsetTop,
    }
  }

  renderSelection() {
    let range = this.overlays.querySelector(".sel-range")
    let cursor = this.overlays.querySelector(".sel-cursor")
    if (!cursor) {
      range = el("div", { className: "sel-range" })
      cursor = el("div", { className: "sel-cursor" })
      this.overlays.append(range, cursor)
    }
    place(cursor, this.box(this.focus))
    const single = this.anchor.col === this.focus.col && this.anchor.row === this.focus.row
    place(range, single ? null : this.box(this.anchor, this.focus))
    this.nameBox.textContent = cellName(this.focus.col, this.focus.row)
    const cell = this.cell(this.active, cellName(this.focus.col, this.focus.row))
    $("bold").classList.toggle("on", !!cell?.get("bold"))
    $("format").value = cell?.get("format") ?? ""
    for (const b of $("fills").children) b.classList.toggle("on", (cell?.get("fill") ?? "") === b.dataset.fill)
  }

  // Each other person's and agent's selected cell on this tab, outlined in
  // their color with their name.
  renderPeers() {
    this.overlays.querySelectorAll(".peer").forEach((n) => n.remove())
    for (const peer of this.peers()) {
      const p = peer.cell?.tab === this.active && parseCell(peer.cell.ref ?? "")
      const box = p && this.box(p)
      if (!box) continue
      const working = peer.agent?.status === "working"
      const tag = el("span", { className: "peer-tag" }, [peer.user.name])
      const node = el("div", { className: `peer${peer.agent ? " is-agent" : ""}${working ? " is-working" : ""}` }, [tag])
      node.style.setProperty("--peer", peer.user.color)
      node.dataset.name = peer.user.name
      place(node, box)
      this.overlays.append(node)
    }
  }

  renderAvatars() {
    const all = [...this.provider.awareness.getStates().entries()].filter(([, s]) => s?.user?.name).map(([id, s]) => ({ id, ...s }))
    $("avatars").replaceChildren(...all.map((p) => avatar(p, p.id === this.provider.awareness.clientID)))
    const mine = this.myAgent()
    inviteButton.hidden = !!mine
    if (!mine) inviteButton.querySelector("span").textContent = "Invite your agent"
  }

  renderTitle() {
    const input = $("sheet-title")
    if (document.activeElement !== input) input.value = this.meta.get("title") ?? ""
  }

  renderTabs() {
    const nav = $("tabs")
    if (nav.querySelector("input")) return // renaming
    const buttons = this.tabIds().map((id) => {
      const b = el("button", { type: "button", className: `tab${id === this.active ? " is-active" : ""}` }, [this.tabName(id)])
      b.dataset.tab = id
      b.addEventListener("click", () => this.switchTab(id))
      b.addEventListener("dblclick", () => this.renameTab(b, id))
      return b
    })
    const add = el("button", { type: "button", className: "tab tab-add", title: "Add a tab" }, ["+"])
    add.addEventListener("click", () => this.addTab())
    nav.replaceChildren(add, ...buttons)
  }

  switchTab(id) {
    if (id === this.active) return
    this.commitEdit()
    this.active = id
    this.anchor = { col: 0, row: 0 }
    this.focus = { col: 0, row: 0 }
    this.dims = null
    this.moved()
    this.render()
  }

  addTab() {
    const names = new Set(this.tabIds().map((id) => this.tabName(id).toLowerCase()))
    let n = this.tabIds().length + 1
    while (names.has(`sheet${n}`)) n++
    const id = uid().slice(0, 8)
    this.transact(() => {
      this.sheets.set(id, tabMap(`Sheet${n}`, {}, {}))
      this.tabs.push([id])
    })
    this.switchTab(id)
  }

  // Renames a tab, and rewrites every formula that named it, so they keep
  // pointing at it.
  renameTab(button, id) {
    const from = this.tabName(id)
    const input = el("input", { className: "tab-rename", value: from, maxLength: 40 })
    button.replaceWith(input)
    input.focus()
    input.select()
    let done = false
    const finish = (save) => {
      if (done) return
      done = true
      const to = input.value.trim().replace(/!/g, "")
      input.remove()
      const taken = this.tabIds().some((other) => other !== id && this.tabName(other).toLowerCase() === to.toLowerCase())
      if (save && to && to !== from && !taken) {
        this.transact(() => {
          this.sheets.get(id).set("name", to)
          for (const tab of this.tabIds()) {
            for (const [, cell] of this.cells(tab)?.entries() ?? []) {
              const before = cell.get("input")
              const after = renameTab(before, from, to)
              if (after !== before) cell.set("input", after)
            }
          }
        })
      } else if (taken) toast(`There's already a tab named ${to}.`)
      this.render()
    }
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") finish(true)
      if (e.key === "Escape") finish(false)
    })
    input.addEventListener("blur", () => finish(true))
  }

  // --- selection and editing ---

  select(col, row, extend = false) {
    this.focus = { col: Math.max(0, col), row: Math.max(0, row) }
    if (!extend) this.anchor = { ...this.focus }
    this.ensureSize()
    this.renderSelection()
    this.syncFormulaBar()
    this.scrollIntoView()
    this.moved()
  }

  // Grows the grid when the selection walks off its edge.
  ensureSize() {
    if (this.tdByRef && (this.focus.row >= this.tdByRef.rows || this.focus.col >= this.tdByRef.cols)) {
      this.build(Math.max(this.tdByRef.rows, this.focus.row + 10), Math.max(this.tdByRef.cols, this.focus.col + 3),
        this.sheets.get(this.active)?.get("widths"))
      this.dims = { ...this.dims, rows: this.tdByRef.rows, cols: this.tdByRef.cols }
      this.renderGrid()
      this.renderPeers()
    }
  }

  moved() {
    if (this.provider.awareness.getLocalState()) this.provider.awareness.setLocalStateField("cell", this.presenceCell())
  }

  scrollIntoView() {
    const box = this.box(this.focus)
    if (!box) return
    const s = this.scroll
    const headH = 26
    const headW = 44
    if (box.top - headH < s.scrollTop) s.scrollTop = box.top - headH
    else if (box.top + box.height > s.scrollTop + s.clientHeight) s.scrollTop = box.top + box.height - s.clientHeight
    if (box.left - headW < s.scrollLeft) s.scrollLeft = box.left - headW
    else if (box.left + box.width > s.scrollLeft + s.clientWidth) s.scrollLeft = box.left + box.width - s.clientWidth
  }

  syncFormulaBar() {
    if (document.activeElement === this.formula) return
    this.formula.value = this.cell(this.active, cellName(this.focus.col, this.focus.row))?.get("input") ?? ""
  }

  // Opens the cell editor over the focused cell, holding `text` (the cell's
  // input for F2, or the key that was typed).
  startEdit(text) {
    const ref = cellName(this.focus.col, this.focus.row)
    const original = this.cell(this.active, ref)?.get("input") ?? ""
    const input = el("input", { className: "cell-editor", spellcheck: false, autocomplete: "off" })
    input.value = text ?? original
    place(input, this.box(this.focus))
    this.overlays.append(input)
    this.editing = { input, ref, tab: this.active, original }
    input.focus()
    input.setSelectionRange(input.value.length, input.value.length)
    this.formula.value = input.value
    input.addEventListener("input", () => { this.formula.value = input.value })
    input.addEventListener("keydown", (e) => {
      e.stopPropagation() // the grid's own keys would act on the cell below
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault()
        this.commitEdit()
        if (e.key === "Enter") this.select(this.focus.col, this.focus.row + (e.shiftKey ? -1 : 1))
        else this.select(this.focus.col + (e.shiftKey ? -1 : 1), this.focus.row)
        this.scroll.focus()
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.cancelEdit()
        this.scroll.focus()
      }
    })
    input.addEventListener("blur", () => { if (this.editing?.input === input) this.commitEdit() })
  }

  commitEdit() {
    const editing = this.editing
    if (!editing) return
    this.editing = null
    editing.input.remove()
    // Only a change you made is written, so opening and closing the editor
    // doesn't put back what the cell held before someone else changed it.
    if (editing.input.value !== editing.original) this.transact(() => this.write(editing.tab, editing.ref, { input: editing.input.value }))
    this.syncFormulaBar()
  }

  cancelEdit() {
    const editing = this.editing
    if (!editing) return
    this.editing = null // first, because removing the input fires its blur
    editing.input.remove()
    this.syncFormulaBar()
  }

  wireGrid() {
    const s = this.scroll
    s.addEventListener("mousedown", (e) => {
      const td = e.target.closest("td")
      if (!td) return
      e.preventDefault()
      this.commitEdit()
      const p = parseCell(td.dataset.ref)
      this.select(p.col, p.row, e.shiftKey)
      s.focus()
      const drag = (m) => {
        const over = document.elementFromPoint(m.clientX, m.clientY)?.closest("td")
        if (over && this.tdByRef.map.get(over.dataset.ref) === over) {
          const q = parseCell(over.dataset.ref)
          if (q.col !== this.focus.col || q.row !== this.focus.row) this.select(q.col, q.row, true)
        }
      }
      const up = () => { removeEventListener("mousemove", drag); removeEventListener("mouseup", up) }
      addEventListener("mousemove", drag)
      addEventListener("mouseup", up)
    })
    s.addEventListener("dblclick", (e) => { if (e.target.closest("td")) this.startEdit() })

    s.addEventListener("keydown", (e) => {
      if (this.editing || e.target !== s) return
      const mod = e.metaKey || e.ctrlKey
      const { col, row } = this.focus
      const moves = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] }
      if (mod && e.key.toLowerCase() === "z") {
        e.preventDefault()
        e.shiftKey ? this.undo.redo() : this.undo.undo()
      } else if (mod && e.key.toLowerCase() === "y") {
        e.preventDefault()
        this.undo.redo()
      } else if (mod && e.key.toLowerCase() === "b") {
        e.preventDefault()
        $("bold").click()
      } else if (moves[e.key]) {
        e.preventDefault()
        this.select(col + moves[e.key][0], row + moves[e.key][1], e.shiftKey)
      } else if (e.key === "Tab") {
        e.preventDefault()
        this.select(col + (e.shiftKey ? -1 : 1), row)
      } else if (e.key === "Enter" || e.key === "F2") {
        e.preventDefault()
        if (e.key === "Enter" && e.shiftKey) this.select(col, row - 1)
        else this.startEdit()
      } else if (e.key === "Delete" || e.key === "Backspace") {
        e.preventDefault()
        this.transact(() => { for (const ref of this.selected()) this.write(this.active, ref, { input: "" }) })
      } else if (e.key.length === 1 && !mod && !e.altKey) {
        e.preventDefault()
        this.startEdit(e.key)
      }
    })

    // Copy and paste plain values: the selection as tab-separated text, and
    // a pasted block from the focused cell down and right.
    s.addEventListener("copy", (e) => {
      const [c1, c2] = [this.anchor.col, this.focus.col].sort((a, b) => a - b)
      const [r1, r2] = [this.anchor.row, this.focus.row].sort((a, b) => a - b)
      const lines = []
      for (let r = r1; r <= r2; r++) {
        const line = []
        for (let c = c1; c <= c2; c++) {
          const ref = cellName(c, r)
          line.push(display(this.value(this.active, ref), this.cell(this.active, ref)?.get("format")))
        }
        lines.push(line.join("\t"))
      }
      e.clipboardData.setData("text/plain", lines.join("\n"))
      e.preventDefault()
    })
    s.addEventListener("paste", (e) => {
      const text = e.clipboardData.getData("text/plain")
      if (!text) return
      e.preventDefault()
      const rows = text.replace(/\r/g, "").replace(/\n$/, "").split("\n").map((line) => line.split("\t"))
      const c1 = Math.min(this.anchor.col, this.focus.col)
      const r1 = Math.min(this.anchor.row, this.focus.row)
      this.transact(() => {
        rows.forEach((line, r) => line.forEach((value, c) => this.write(this.active, cellName(c1 + c, r1 + r), { input: value })))
      })
      this.anchor = { col: c1, row: r1 }
      this.select(c1 + rows[0].length - 1, r1 + rows.length - 1, true)
    })

    // The formula bar edits the focused cell.
    this.formula.addEventListener("focus", () => this.commitEdit())
    this.formula.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        this.setInput(cellName(this.focus.col, this.focus.row), this.formula.value)
        this.scroll.focus()
        this.select(this.focus.col, this.focus.row + 1)
      } else if (e.key === "Escape") {
        this.formula.blur()
        this.syncFormulaBar()
        this.scroll.focus()
      }
    })
    this.formula.addEventListener("blur", () => setTimeout(() => this.syncFormulaBar(), 0))

    const title = $("sheet-title")
    title.addEventListener("change", () => this.transact(() => this.meta.set("title", title.value.trim())))
    title.addEventListener("keydown", (e) => { if (e.key === "Enter") title.blur() })
  }

  wireToolbar() {
    // Mousedown on a tool would take focus from the grid and close a cell
    // editor without saving. Keep focus where it is.
    for (const b of document.querySelectorAll(".sheet-toolbar button")) b.addEventListener("mousedown", (e) => e.preventDefault())
    $("undo").addEventListener("click", () => this.undo.undo())
    $("redo").addEventListener("click", () => this.undo.redo())
    $("bold").addEventListener("click", () => {
      const on = !this.cell(this.active, cellName(this.focus.col, this.focus.row))?.get("bold")
      this.format({ bold: on })
    })
    $("format").addEventListener("change", (e) => {
      this.format({ format: e.target.value })
      this.scroll.focus()
    })
    $("fills").replaceChildren(...FILLS.map(([color, name]) => {
      const b = el("button", { type: "button", className: "fill", title: `${name} fill` })
      b.dataset.fill = color
      b.style.background = color || "transparent"
      b.addEventListener("mousedown", (e) => e.preventDefault())
      b.addEventListener("click", () => this.format({ fill: color }))
      return b
    }))
  }

  // --- asks ---

  wireAskForm() {
    const form = $("ask-form")
    const input = $("ask-input")
    form.addEventListener("submit", (e) => {
      e.preventDefault()
      const prompt = input.value.trim()
      if (!prompt) return
      this.ask(prompt)
      input.value = ""
    })
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        form.requestSubmit()
      }
    })
  }

  ask(prompt) {
    const id = uid()
    this.doc.transact(() => {
      const ask = new Y.Map()
      this.asks.set(id, ask)
      const fields = {
        owner: me.id, askedBy: me.name, prompt, tab: this.active, cell: cellName(this.focus.col, this.focus.row),
        status: "asked", createdAt: Date.now(),
      }
      for (const [key, value] of Object.entries(fields)) ask.set(key, value)
    }, "ask")
    this.summonAgent(id)
  }

  // An ask needs your agent. When it can't come, the ask fails with why.
  async summonAgent(id) {
    if (this.myAgent()) return
    const problem = await inviteAgent()
    if (problem) this.update(id, { status: "failed", error: CANT_COME[problem][1] })
  }

  update(id, fields) {
    const ask = this.asks.get(id)
    if (!ask) return
    this.doc.transact(() => {
      for (const [key, value] of Object.entries(fields)) {
        if (value === undefined) ask.delete(key)
        else ask.set(key, value)
      }
    }, "ask")
  }

  // Puts back every cell the ask wrote, as it was before the ask, unless
  // someone has changed the cell since. Not part of anyone's undo history.
  undoAsk(id) {
    const ask = this.asks.get(id)
    const before = ask?.get("before")
    let kept = 0
    this.doc.transact(() => {
      for (const [key, was] of before?.entries() ?? []) {
        const at = key.lastIndexOf("!")
        const tab = key.slice(0, at)
        const ref = key.slice(at + 1)
        const cells = this.cells(tab)
        const cell = cells?.get(ref)
        if (!cell || cell.get("ask") !== id) { kept++; continue }
        const old = was instanceof Y.Map ? was.toJSON() : (was ?? {})
        if (Object.keys(old).length === 0) { cells.delete(ref); continue }
        for (const field of CELL_FIELDS) {
          if (field in old) cell.set(field, old[field])
          else cell.delete(field)
        }
      }
      ask.set("status", "undone")
      ask.set("decidedBy", me.name)
      if (kept) ask.set("kept", kept)
    }, "undo-ask")
  }

  renderAsks() {
    const list = $("asks")
    const asks = [...this.asks.entries()].sort(([, a], [, b]) => (a.get("createdAt") ?? 0) - (b.get("createdAt") ?? 0))
    const seen = new Set()
    for (const [id, ask] of asks) {
      seen.add(id)
      let card = list.querySelector(`[data-ask="${CSS.escape(id)}"]`)
      if (!card) {
        card = el("li", { className: "ask-card" })
        card.dataset.ask = id
        list.append(card)
        list.scrollTop = list.scrollHeight
      }
      this.fillCard(card, id, ask)
    }
    for (const card of list.querySelectorAll(".ask-card")) if (!seen.has(card.dataset.ask)) card.remove()
    list.classList.toggle("is-empty", asks.length === 0)
  }

  fillCard(card, id, ask) {
    const status = ask.get("status")
    const owner = ask.get("owner")
    const agent = this.peers().find((p) => p.agent?.owner === owner)
    const agentName = `${ask.get("askedBy")}'s agent`
    const color = agent?.user?.color ?? "#b8bfd3"
    const say = ask.get("say") ?? ""
    const written = ask.get("written")
    const key = [status, say, written, ask.get("error"), ask.get("prompt"), !!agent, ask.get("kept"), card.classList.contains("revising")].join("\u0000")
    if (card.dataset.key === key) return
    card.dataset.key = key
    card.dataset.status = status
    card.style.setProperty("--agent", color)

    const parts = [
      el("div", { className: "ask-who" }, [ask.get("askedBy") ?? "Someone", el("span", { className: "ask-tab" }, [`on ${this.tabName(ask.get("tab"))}`])]),
      el("p", { className: "ask-prompt" }, [ask.get("prompt") ?? ""]),
    ]
    const reply = el("div", { className: "ask-reply" }, [dot(color), el("strong", {}, [agentName])])
    parts.push(reply)

    if (OPEN.has(status)) {
      const label = el("span", { className: "working-label" })
      label.dataset.started = String((status === "working" && ask.get("startedAt")) || "")
      label.dataset.waiting = agent ? "" : "true"
      label.textContent = workingText(label)
      reply.append(label)
      parts.push(el("div", { className: "ask-bar" }, [button("Stop", () => this.update(id, { status: "stopped" }))]))
    } else if (status === "done") {
      if (say) parts.push(el("p", { className: "ask-say" }, [say]))
      reply.append(el("span", { className: "ask-meta" }, [`wrote ${written ?? 0} cell${written === 1 ? "" : "s"}`]))
      parts.push(el("div", { className: "ask-bar" }, [
        button("Undo", () => this.undoAsk(id)),
        button("Ask for a change", () => this.revise(card, id, ask)),
      ]))
    } else if (status === "failed") {
      parts.push(el("p", { className: "ask-error" }, [`Couldn't answer: ${ask.get("error") ?? "something went wrong"}.`]))
      parts.push(el("div", { className: "ask-bar" }, [
        button("Dismiss", () => this.update(id, { status: "stopped" })),
        button("Try again", () => {
          this.update(id, { status: "asked", error: undefined })
          this.summonAgent(id)
        }),
      ]))
    } else if (status === "undone") {
      const kept = ask.get("kept")
      reply.append(el("span", { className: "ask-meta" }, [`undone by ${ask.get("decidedBy") ?? "someone"}`]))
      if (kept) parts.push(el("p", { className: "ask-say" }, [`${kept} cell${kept === 1 ? " was" : "s were"} changed after, so ${kept === 1 ? "it stays" : "they stay"}.`]))
    } else if (status === "stopped") {
      reply.append(el("span", { className: "ask-meta" }, ["stopped"]))
    }
    card.replaceChildren(...parts)
  }

  // A follow-up: the same ask goes back to the agent with what to change.
  // Its record of the cells from before stays, so Undo still goes all the
  // way back.
  revise(card, id, ask) {
    const bar = card.querySelector(".ask-bar")
    const input = el("input", { className: "revise-input", placeholder: "What should change?", maxLength: 300 })
    const form = el("form", { className: "revise-form" }, [input, el("button", { type: "submit", className: "pill pill-dark" }, ["Send"])])
    form.addEventListener("submit", (e) => {
      e.preventDefault()
      const prompt = input.value.trim()
      if (!prompt) return
      card.classList.remove("revising")
      this.update(id, { prompt, previous: ask.get("prompt"), status: "asked", say: undefined, written: undefined })
      this.summonAgent(id)
    })
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        card.classList.remove("revising")
        form.replaceWith(bar)
      }
    })
    card.classList.add("revising")
    bar.replaceWith(form)
    input.focus()
  }

  tickTimers() {
    for (const label of document.querySelectorAll(".working-label")) label.textContent = workingText(label)
  }
}

// --- helpers -----------------------------------------------------------------

function tabMap(name, cells, widths) {
  const tab = new Y.Map()
  tab.set("name", name)
  const cellsMap = new Y.Map()
  for (const [ref, fields] of Object.entries(cells)) {
    const cell = new Y.Map()
    for (const [key, value] of Object.entries(fields)) cell.set(key, value)
    cellsMap.set(ref, cell)
  }
  tab.set("cells", cellsMap)
  const widthsMap = new Y.Map()
  for (const [col, px] of Object.entries(widths)) widthsMap.set(col, px)
  tab.set("widths", widthsMap)
  return tab
}

function workingText(label) {
  const started = Number(label.dataset.started)
  if (!started) return label.dataset.waiting ? "waiting for the agent to join…" : "starting…"
  return `working for ${Math.max(0, Math.floor((Date.now() - started) / 1000))}s`
}

function place(node, box) {
  if (!box) {
    node.hidden = true
    return
  }
  node.hidden = false
  Object.assign(node.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px` })
}

function el(tag, props = {}, children = []) {
  const node = document.createElement(tag)
  for (const [key, value] of Object.entries(props)) {
    if (key === "style") node.setAttribute("style", value)
    else node[key] = value
  }
  node.append(...children)
  return node
}

function button(text, onClick) {
  const node = el("button", { type: "button", className: "pill pill-small" }, [text])
  node.addEventListener("click", onClick)
  return node
}

function avatar(peer, isMe) {
  if (peer.agent) {
    const node = dot(peer.user.color)
    node.title = peer.user.name
    node.classList.toggle("is-working", peer.agent.status === "working")
    return node
  }
  const node = el("span", { className: "avatar", title: isMe ? `${peer.user.name} (you)` : peer.user.name }, [peer.user.name.slice(0, 1)])
  node.style.background = peer.user.color
  return node
}

function dot(color) {
  const node = el("span", { className: "agent-dot" })
  node.style.setProperty("--agent", color)
  return node
}
