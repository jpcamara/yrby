// Opaque-state demo: a co-op sudoku.
// Shared state is a Y.Map keyed by cell ("r0c0" through "r8c8") holding the
// digit typed there. Different cells merge; the same cell is last-writer-wins.
// The puzzle is a second map the server wrote once (SudokuPuzzle). A Ruby
// process joins as a player and checks the grid: it writes the clashing cells,
// the progress, and hints into the document (SudokuPeer). This page draws
// what is in the document and asks for a hint by writing into it too.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS) }

const gridEl = document.getElementById("grid")
const statusEl = document.getElementById("status")
const presenceEl = document.getElementById("presence")
const progressEl = document.getElementById("progress")
const hintEl = document.getElementById("hint")
const inviteEl = document.querySelector(".invite-checker")
const documentId = gridEl.dataset.documentId

const ydoc = new Y.Doc()
const givens = ydoc.getMap("givens")
const grid = ydoc.getMap("grid")
const conflicts = ydoc.getMap("conflicts")
const progress = ydoc.getMap("progress")
const requests = ydoc.getMap("requests")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
const awareness = provider.awareness
awareness.setLocalStateField("user", user)
window.__yrb = { provider, ydoc, givens, grid, conflicts, progress, requests, user }

// The cells. The one you focus is the one your presence says you are on.
const key = (r, c) => `r${r}c${c}`
const cells = {}
for (let r = 0; r < 9; r++) for (let c = 0; c < 9; c++) {
  const el = document.createElement("div")
  el.className = "cell" + (c % 3 === 2 && c < 8 ? " br" : "") + (r % 3 === 2 && r < 8 ? " bb" : "")
  el.tabIndex = 0
  el.dataset.cell = key(r, c)
  el.setAttribute("role", "gridcell")
  el.addEventListener("focus", () => awareness.setLocalStateField("cell", el.dataset.cell))
  el.addEventListener("keydown", (e) => onKey(e, r, c))
  gridEl.appendChild(el)
  cells[key(r, c)] = el
}

const MOVES = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }
function onKey(e, r, c) {
  if (MOVES[e.key]) {
    e.preventDefault()
    const [dr, dc] = MOVES[e.key]
    cells[key((r + dr + 9) % 9, (c + dc + 9) % 9)].focus()
    return
  }
  const k = key(r, c)
  if (givens.has(k)) return // the puzzle's cells stay as they are
  if (/^[1-9]$/.test(e.key)) grid.set(k, Number(e.key))
  else if (["Backspace", "Delete", "0", " "].includes(e.key)) grid.delete(k)
  else return
  e.preventDefault() // the key was for the cell, not the page
}

// Everything on screen comes from the document and the presence: the digits,
// the puzzle, the checker's flags, and who is on which cell.
function render() {
  const who = {}
  for (const [id, s] of awareness.getStates()) {
    if (id !== awareness.clientID && s?.user && s.cell) (who[s.cell] ||= []).push(s.user)
  }
  for (const [k, el] of Object.entries(cells)) {
    const given = givens.get(k)
    el.textContent = given ?? grid.get(k) ?? ""
    el.classList.toggle("given", given != null)
    el.classList.toggle("conflict", conflicts.has(k))
    const peers = who[k]
    el.classList.toggle("here", !!peers)
    if (peers) { el.style.setProperty("--c", peers[0].color); el.dataset.who = peers.map((u) => u.name).join(", ") }
    else { el.style.removeProperty("--c"); delete el.dataset.who }
  }
  renderProgress()
}

const checker = () => [...awareness.getStates().values()].find((s) => s?.checker)
function renderProgress() {
  const filled = progress.get("filled")
  const n = progress.get("conflicts")
  let text = "not checked yet"
  if (progress.get("solved")) text = "solved"
  else if (filled != null) text = `${filled}/81 filled` + (n ? `, ${n} clashing` : "")
  progressEl.textContent = `${text} · ${checker() ? "the checker is here" : "no checker here"}`
  hintEl.disabled = requests.has("hint")
  hintEl.textContent = requests.has("hint") ? "Hint requested…" : "Ask for a hint"
  if (inviteEl) { inviteEl.disabled = !!checker(); inviteEl.textContent = checker() ? "The checker is here" : "Invite the checker" }
}

function renderPresence() {
  presenceEl.replaceChildren(...[...awareness.getStates().values()].filter((s) => s?.user).map((s) => {
    const chip = document.createElement("span")
    chip.className = "chip"
    chip.style.background = s.user.color
    chip.textContent = s.user.name + (s.user.name === user.name && !s.checker ? " (you)" : "") + (s.status ? ` · ${s.status}` : "")
    return chip
  }))
}

// A hint is asked for in the document. The checker fills a cell and takes
// the request out, whether it is here now or joins later.
hintEl.addEventListener("click", () => requests.set("hint", Date.now()))

// The invite is a fetch, not a navigation. Under Falcon the answer is a
// stream that stays open while the checker runs, and this page holds it:
// leaving the page closes it, and the checker goes with it. Under Puma the
// answer is an empty 204 and the checker runs on its own.
inviteEl?.closest("form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  const response = await fetch(e.target.action, { method: "POST", headers: { Accept: "text/event-stream" } })
  const reader = response.body?.getReader()
  while (reader && !(await reader.read()).done) { /* hold the stream until the checker leaves */ }
})

for (const map of [givens, grid, conflicts, progress, requests]) map.observe(render)
awareness.on("update", () => { render(); renderPresence() })

statusEl.textContent = `connecting as ${user.name}…`
provider.onStatusChange(({ status }) => {
  statusEl.textContent = status === "synced" ? `synced as ${user.name}` : `${status}…`
})
render()
renderPresence()
provider.connect()
