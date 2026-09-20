// Opaque-state demo: cursors with opinions.
// Shared state is a Y.Map of signs (id -> Y.Map{ x, y, text }) and a Y.Map of
// party controls ({ enabled }). People's cursors are their awareness, as on
// any multiplayer page. The guests are Ruby processes' peers on the same
// document (see app/lib/guest.rb): their presence carries a name, a color, a
// trait, the sign they stand at, and their last decision. This page draws
// what is in the document and the presence, and glides each guest to the
// sign its presence names. Jev picks which sign; yrby carries where it is.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const W = 1000, H = 560, SIGN_W = 180, SIGN_H = 100
const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
// The guests' slots around a sign, in the order the party seats them.
const RING = ["Snack Goblin", "Networker", "Introvert", "Rubyist", "Night Owl", "Cat Person", "Coffee Snob", "Lurker"]
const SAY_FOR = 3000    // ms a move stays labeled on a guest's chip
const PULSE_FOR = 400   // ms a chip pulses when its guest was asked and stayed
const CHIP_H = 36       // a guest chip: name and trait
const ROUND_GAP = 1500  // ms of quiet that ends a round of decisions
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const $ = (id) => document.getElementById(id)
const params = new URLSearchParams(location.search)
const user = { name: (params.get("as") || "").trim().slice(0, 24) || pick(NAMES), color: pick(COLORS) }
if (params.get("stage") === "1") document.body.classList.add("stage") // a recording: the board fills the window

const board = $("board"), stage = $("stage"), layer = $("cursors"), labelLayer = $("labels")
const statusEl = $("status"), hudEl = $("hud"), inviteEl = $("invite"), homeEl = $("home"), inviteStatus = $("invite-status")
const documentId = board.dataset.documentId

const ydoc = new Y.Doc()
const signs = ydoc.getMap("signs")
const party = ydoc.getMap("party")
const provider = new ActionCableProvider(ydoc, createConsumer(), "DocumentChannel", { id: documentId })
const awareness = provider.awareness
awareness.setLocalStateField("user", user)

// The board is 1000x560 in document coordinates and scales down to fit; on
// a stage it scales up to fill what is left of the window. Pointer math
// uses the stage's rendered size, so it holds under any zoom.
function fit() {
  const byWidth = (board.parentElement.clientWidth - 2) / W
  let scale = Math.min(1, byWidth)
  if (document.body.classList.contains("stage")) {
    const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1
    const foot = $("foot")?.offsetHeight || 0
    scale = Math.min(byWidth, (window.innerHeight / zoom - board.offsetTop - foot - 16) / H)
    board.style.width = `${Math.floor(W * scale)}px`
  }
  stage.style.transform = `scale(${scale})`
  board.style.height = `${Math.round(H * scale)}px`
}
new ResizeObserver(fit).observe(board.parentElement)
window.addEventListener("resize", fit)
fit()
const shown = () => stage.getBoundingClientRect().width / W // viewport px per board unit
const toBoard = (e) => { const r = stage.getBoundingClientRect(), k = r.width / W; return [(e.clientX - r.left) / k, (e.clientY - r.top) / k] }
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))

// Signs. Ids are what the guests choose between, so they stay plain.
function addSign(x, y, text = "", id = `s${crypto.randomUUID().replace(/-/g, "").slice(0, 8)}`) {
  const m = new Y.Map()
  m.set("x", Math.round(clamp(x, 0, W - SIGN_W))); m.set("y", Math.round(clamp(y, 0, H - SIGN_H))); m.set("text", text)
  signs.set(id, m)
  return id
}
stage.addEventListener("dblclick", (e) => {
  if (e.target !== stage && e.target !== layer) return
  const [x, y] = toBoard(e)
  const id = addSign(x - SIGN_W / 2, y - SIGN_H / 2)
  els.get(id)?._ta.focus()
})

function makeDraggable(el, m) {
  el.addEventListener("pointerdown", (e) => {
    if (e.target.tagName === "TEXTAREA" || e.target.tagName === "BUTTON") return
    el.setPointerCapture(e.pointerId)
    awareness.setLocalStateField("dragging", el.dataset.id) // the hand's chip moves off the card meanwhile
    const sx = e.clientX, sy = e.clientY, ox = m.get("x"), oy = m.get("y"), k = shown()
    const onMove = (ev) => ydoc.transact(() => {
      m.set("x", Math.round(clamp(ox + (ev.clientX - sx) / k, 0, W - SIGN_W)))
      m.set("y", Math.round(clamp(oy + (ev.clientY - sy) / k, 0, H - SIGN_H)))
    })
    const onUp = () => { el.removeEventListener("pointermove", onMove); el.removeEventListener("pointerup", onUp); awareness.setLocalStateField("dragging", null) }
    el.addEventListener("pointermove", onMove)
    el.addEventListener("pointerup", onUp)
  })
}

const els = new Map()
function renderSigns() {
  for (const [id, el] of els) if (!signs.has(id)) { el.remove(); els.delete(id) }
  signs.forEach((m, id) => {
    let el = els.get(id)
    if (!el) {
      el = document.createElement("div"); el.className = "sign"; el.dataset.id = id
      const ta = document.createElement("textarea")
      ta.placeholder = "what does the sign say?"
      ta.addEventListener("input", () => m.set("text", ta.value))
      ta.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); ta.blur() } })
      const x = document.createElement("button"); x.type = "button"; x.className = "x"; x.textContent = "×"; x.title = "Take the sign down"
      x.addEventListener("click", () => signs.delete(id))
      el.append(ta, x); el._ta = ta
      makeDraggable(el, m)
      stage.insertBefore(el, layer); els.set(id, el)
    }
    el.style.left = `${m.get("x")}px`
    el.style.top = `${m.get("y")}px`
    const t = m.get("text") ?? ""
    if (el._ta.value !== t && document.activeElement !== el._ta) el._ta.value = t
  })
}
signs.observeDeep(renderSigns)

// This person's cursor, in board coordinates, for everyone else's page.
let lastSent = 0
stage.addEventListener("pointermove", (e) => {
  const t = performance.now()
  if (t - lastSent < 40) return
  lastSent = t
  const [x, y] = toBoard(e)
  awareness.setLocalStateField("cursor", { x: Math.round(x), y: Math.round(y) })
})
stage.addEventListener("pointerleave", () => awareness.setLocalStateField("cursor", null))

// Where a guest stands. At a sign: one of the slots on the card's perimeter,
// outside its bounds, so no chip covers the card or another guest at it.
// Slots are top, left, bottom, right, then the same four one step further
// out, then two more steps above and below, with each chip in the card's
// own column or row; a card near an edge seats its crowd in a stack on the
// side that has room. A card's slots are
// a map that persists: a guest arriving takes the lowest free slot, a
// guest leaving frees its own, and nobody else moves. The map resets when
// the card's crowd is empty or the card is gone. At the wall: the guest's
// home spot, chip toward the board.
const CHIP_W = 176
const order = (name) => { const i = RING.indexOf(name); return i >= 0 ? i : 8 + [...name].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 8, 0) }
function chipRect({ x, y, o }) {
  const left = o.endsWith("l") ? x - 14 - CHIP_W : x + 14
  const top = o.startsWith("u") ? y - 4 - CHIP_H : y + 20
  return { left, top, right: left + CHIP_W, bottom: top + CHIP_H }
}
const onBoard = (r) => r.left >= -12 && r.right <= W + 12 && r.top >= -12 && r.bottom <= H + 12
function slots(x, y) {
  const w = SIGN_W, h = SIGN_H, g = 6, step = CHIP_H + 4, below = h + g + 24 // room for the label under the card
  return [
    { x: x + 10, y: y - 30, o: "ur" },            // top: chip above, over the card's top
    { x: x - g, y: y + h / 2 - 10, o: "l" },      // left: chip to the left
    { x: x + 10, y: y + below, o: "r" },          // bottom: chip below, under the card
    { x: x + w + g, y: y + h / 2 - 10, o: "r" },  // right: chip to the right
    { x: x + 10, y: y - 30 - step, o: "ur" },
    { x: x - g, y: y + h / 2 - 10 - step, o: "l" },
    { x: x + 10, y: y + below + step, o: "r" },
    { x: x + w + g, y: y + h / 2 - 10 - step, o: "r" },
    { x: x + 10, y: y - 30 - 2 * step, o: "ur" },
    { x: x + 10, y: y + below + 2 * step, o: "r" },
    { x: x + 10, y: y - 30 - 3 * step, o: "ur" },
    { x: x + 10, y: y + below + 3 * step, o: "r" },
  ]
}
const seats = new Map() // sign id -> Map(guest name -> slot index)
// Give every guest at a sign a seat: newcomers take the lowest free slot
// whose chip is on the board (in party order when several come at once).
function seat(states) {
  const at = new Map()
  for (const s of states) if (s?.guest && s.at && signs.has(s.at)) (at.get(s.at) || at.set(s.at, []).get(s.at)).push(s.user.name)
  for (const id of [...seats.keys()]) if (!at.has(id)) seats.delete(id)
  for (const [id, names] of at) {
    const map = seats.get(id) || seats.set(id, new Map()).get(id)
    for (const name of [...map.keys()]) if (!names.includes(name)) map.delete(name)
    const m = signs.get(id), all = slots(m.get("x"), m.get("y"))
    for (const name of names.filter((n) => !map.has(n)).sort((a, b) => order(a) - order(b))) {
      const taken = new Set(map.values())
      let index = all.findIndex((p, i) => !taken.has(i) && onBoard(chipRect(p)))
      if (index < 0) index = all.findIndex((_, i) => !taken.has(i))
      map.set(name, index < 0 ? all.length - 1 : index)
    }
  }
}
// A guest's destination: where, and which card (or the wall) it belongs to.
function placeFor(state) {
  const m = state.at ? signs.get(state.at) : null
  if (!m) { const [hx, hy] = state.home || [W / 2, H / 2]; return { x: hx, y: hy, o: hx + 14 + CHIP_W > W ? "l" : "r", dest: "wall" } }
  const index = seats.get(state.at)?.get(state.user.name) ?? 0
  return { ...slots(m.get("x"), m.get("y"))[index], dest: state.at }
}

const ARROW = '<svg class="arrow" width="22" height="26" viewBox="0 0 22 26"><path d="M2 2 L2 20 L7 15.5 L10.5 23.5 L14 22 L10.5 14 L17.5 14 Z" fill="var(--c)" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>'
const cursors = new Map() // awareness clientID -> { el, pos, trip, dest, place, arrived }
const guestSeen = new Map() // guest name -> the decision last noticed: { at, where, moved }
const pendingLabels = new Map() // guest name -> a label waiting for the chip to arrive
const rounds = { n: 0, lastActivity: 0, ms: [], known: new Map() } // known: guest name -> decision.at last counted

function cursorEl(id, s) {
  let c = cursors.get(id)
  if (c) return c
  const el = document.createElement("div")
  el.className = s.guest ? "cursor guest" : "cursor human"
  el.innerHTML = `${ARROW}<div class="tag"><div class="chip"><span class="name"></span>${s.guest ? '<span class="trait"></span>' : ""}</div></div>`
  layer.appendChild(el)
  c = { el, pos: s.guest ? [s.home?.[0] ?? W / 2, s.home?.[1] ?? H / 2] : null, trip: null, dest: null, place: null, arrived: false }
  cursors.set(id, c)
  return c
}

// A trip: a fixed-length ease-in-out from where the chip is to its seat,
// starting a moment later for each guest down the party's order, so a
// burst of departures fans out. The chip's side is set once, from the
// destination. A new destination mid-trip starts a new trip from wherever
// the chip is; the same destination moving (a card being dragged) keeps
// the trip, aimed at the live seat; a chip at rest on a card follows it.
const TRIP = 900, FAN = 40, FAN_MAX = 300
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2)
function move(c, s, place, now) {
  const to = [place.x, place.y]
  const same = c.dest === place.dest
  if (c.trip && same) {
    c.trip.to = to // the card moved under a chip on its way: aim at the live seat
  } else if (!c.trip && same && c.arrived) {
    c.pos = to // at rest on a moving card: follow it
  } else if (!same || !c.arrived || Math.hypot(to[0] - c.pos[0], to[1] - c.pos[1]) > 0.5) {
    c.trip = { from: [...c.pos], to, start: now + Math.min(FAN_MAX, order(s.user.name) * FAN) }
    c.arrived = false
  }
  c.dest = place.dest
  c.place = place
  if (c.trip) {
    const t = Math.min(1, Math.max(0, (now - c.trip.start) / TRIP)), k = ease(t)
    c.pos = [c.trip.from[0] + (c.trip.to[0] - c.trip.from[0]) * k, c.trip.from[1] + (c.trip.to[1] - c.trip.from[1]) * k]
    if (t >= 1) { c.trip = null; c.arrived = true; return true }
  }
  return false
}

// A guest that walked somewhere gets a label when it arrives: where, and
// how sure. One that was asked and stayed gets a pulse of its chip when
// the answer lands. A round that moves nobody shows nothing but the HUD.
function notice(s, chipEl) {
  const d = s.decision
  if (!d) return
  const seen = guestSeen.get(s.user.name)
  if (seen && seen.at === d.at) return
  const moved = seen ? seen.where !== s.at : !!s.at
  guestSeen.set(s.user.name, { at: d.at, where: s.at, moved })
  if (moved && s.at) pendingLabels.set(s.user.name, { p: Number(d.p) })
  else { chipEl.classList.remove("pulse"); void chipEl.offsetWidth; chipEl.classList.add("pulse"); setTimeout(() => chipEl.classList.remove("pulse"), PULSE_FOR) }
}

// Decision labels live on a layer above every cursor, so no chip can hide
// one. A label is placed once, when its chip arrives, against the settled
// layout: directly above its own chip; when another label has that spot
// it climbs, a label height at a time, up to two; when a climb would
// leave the board or land on a chip or a card it goes directly below its
// chip instead, and may step down twice the same way; after that it may
// sit beside its chip, to the right, then the left. If nothing is free it
// drops its probability and tries once more; if still nothing is free it
// takes the first spot that covers no chip or card, and failing even that
// it shows no label: the chip's arrival shows the move. From then on it
// rides with its chip. Positions are in board units.
const LABEL_GAP = 3
const labels = new Map() // guest name -> { el, dx, dy, until }
const overlaps = (a, b) => a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top
const onBoardRect = (r) => r.left >= -4 && r.right <= W + 4 && r.top >= 0 && r.bottom <= H
function spotsFor(el, chip, flip, blocks) {
  const w = el.offsetWidth, h = el.offsetHeight
  const left = flip ? chip.right - w : chip.left
  const at = (l, t) => ({ left: l, top: t, right: l + w, bottom: t + h })
  const free = (r) => onBoardRect(r) && !blocks.some((b) => overlaps(r, b))
  const spots = []
  for (let i = 0; i < 3; i++) { const r = at(left, chip.top - LABEL_GAP - h - i * (h + LABEL_GAP)); if (!free(r)) break; spots.push(r) }
  for (let i = 0; i < 3; i++) { const r = at(left, chip.bottom + LABEL_GAP + i * (h + LABEL_GAP)); if (!free(r)) break; spots.push(r) }
  for (const r of [at(chip.right + LABEL_GAP, chip.top), at(chip.left - LABEL_GAP - w, chip.top)]) if (free(r)) spots.push(r)
  return spots
}
function placeLabel(name, text, chip, flip, blocks, now) {
  let entry = labels.get(name)
  if (!entry) { const el = document.createElement("div"); el.className = "label"; labelLayer.appendChild(el); entry = { el }; labels.set(name, entry) }
  const el = entry.el
  el.textContent = text
  const placed = [...labels.values()].filter((l) => l !== entry && l.rect).map((l) => l.rect)
  let spots = spotsFor(el, chip, flip, blocks)
  let spot = spots.find((r) => !placed.some((p) => overlaps(r, p)))
  if (!spot && / · \d\.\d\d$/.test(text)) {
    el.textContent = text.replace(/ · \d\.\d\d$/, "")
    spots = spotsFor(el, chip, flip, blocks)
    spot = spots.find((r) => !placed.some((p) => overlaps(r, p)))
  }
  if (!spot) spot = spots[0]
  if (!spot) { el.remove(); labels.delete(name); return }
  Object.assign(entry, { dx: spot.left - chip.left, dy: spot.top - chip.top, rect: spot, until: now + SAY_FOR })
}
function rideLabels(now) {
  for (const [name, l] of labels) {
    if (now > l.until || !l.chip) { l.el.remove(); labels.delete(name); continue }
    const left = l.chip.left + l.dx, top = l.chip.top + l.dy
    l.rect = { left, top, right: left + l.el.offsetWidth, bottom: top + l.el.offsetHeight }
    l.el.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`
  }
}

// A chip's box in board units, from the cursor's tip and the chip's size.
function chipBox(pos, chipEl, flip, up, top = 20) {
  const w = chipEl.offsetWidth, h = chipEl.offsetHeight
  const left = flip ? pos[0] - 14 - w : pos[0] + 14
  const y = up ? pos[1] - 4 - h : pos[1] + top
  return { left, top: y, right: left + w, bottom: y + h }
}

// Rounds: decisions that land close together are one round. The HUD shows
// the latency spread as the answers arrive.
function noteRound(states, now) {
  const guests = states.filter((s) => s?.guest)
  if (!guests.length) { hudEl.hidden = true; return }
  const deciding = guests.some((s) => s.status === "deciding")
  const landed = guests.filter((s) => s.decision && rounds.known.get(s.user.name) !== s.decision.at)
  if ((deciding || landed.length) && now - rounds.lastActivity > ROUND_GAP) { rounds.n++; rounds.ms = [] }
  if (deciding || landed.length) rounds.lastActivity = now
  for (const s of landed) { rounds.known.set(s.user.name, s.decision.at); rounds.ms.push(Number(s.decision.ms)) }
  const spread = rounds.ms.length ? `${Math.round(Math.min(...rounds.ms))}–${Math.round(Math.max(...rounds.ms))} ms` : "…"
  hudEl.textContent = rounds.n ? `round ${rounds.n} · ${guests.length} guests asked Jev · ${spread}` : `${guests.length} guests arriving`
  hudEl.hidden = false
}

function frame(now) {
  const states = [...awareness.getStates().entries()]
  seat(states.map(([, s]) => s))
  const live = new Set()
  const chips = [], arrivals = []
  for (const [id, s] of states) {
    if (!s?.user) continue
    if (!s.guest && !s.cursor) continue
    live.add(id)
    const c = cursorEl(id, s)
    let x, y
    if (s.guest) {
      const chipEl = c.el.querySelector(".chip")
      notice(s, chipEl)
      const place = placeFor(s)
      const arrived = move(c, s, place, now)
      ;[x, y] = c.pos
      const flip = c.place.o.endsWith("l"), up = c.place.o.startsWith("u")
      c.el.classList.toggle("flip", flip)
      c.el.classList.toggle("up", up)
      c.el.querySelector(".trait").textContent = s.trait || ""
      const chip = chipBox(c.pos, chipEl, flip, up)
      chips.push(chip)
      const label = labels.get(s.user.name)
      if (label) label.chip = chip
      if (arrived && pendingLabels.has(s.user.name)) arrivals.push({ s, chip, flip })
    } else {
      x = s.cursor.x; y = s.cursor.y
      // A hand dragging a card keeps its chip below the card, off the title.
      const held = s.dragging && signs.get(s.dragging)
      const top = held ? held.get("y") + SIGN_H + 6 - y : 20
      c.el.querySelector(".tag").style.top = held ? `${top}px` : ""
      chips.push(chipBox([x, y], c.el.querySelector(".chip"), false, false, top))
    }
    c.el.style.setProperty("--c", s.user.color || "#111")
    c.el.querySelector(".name").textContent = s.user.name + (id === awareness.clientID ? " (you)" : "")
    c.el.style.transform = `translate(${x}px, ${y}px)`
  }
  for (const [id, c] of cursors) if (!live.has(id)) { c.el.remove(); cursors.delete(id) }
  for (const name of [...labels.keys()]) if (!states.some(([, s]) => s?.guest && s.user.name === name)) { labels.get(name).el.remove(); labels.delete(name) }
  if (arrivals.length) {
    const cards = [...signs.values()].map((m) => ({ left: m.get("x"), top: m.get("y"), right: m.get("x") + SIGN_W, bottom: m.get("y") + SIGN_H }))
    for (const { s, chip, flip } of arrivals.sort((a, b) => a.chip.top - b.chip.top)) {
      const { p } = pendingLabels.get(s.user.name)
      pendingLabels.delete(s.user.name)
      const text = String(signs.get(s.at)?.get("text") ?? "(gone)").toUpperCase()
      placeLabel(s.user.name, `→ ${text.length > 20 ? `${text.slice(0, 19)}…` : text} · ${p.toFixed(2)}`, chip, flip, [...chips, ...cards], now)
      const placed = labels.get(s.user.name)
      if (placed) placed.chip = chip
    }
  }
  rideLabels(now)
  noteRound(states.map(([, s]) => s), now)
  requestAnimationFrame(frame)
}
requestAnimationFrame(frame)

// The invite. Presence, not the response, says the guests are here.
let inviteController = null
const guestStates = () => [...awareness.getStates().values()].filter((s) => s?.guest)
function renderParty() {
  // The document says the party is over: drop the stream that held it,
  // whichever browser said so.
  if (party.get("enabled") === false && inviteController) { inviteController.abort(); inviteController = null }
  const guests = guestStates()
  const model = guests.map((s) => s.decision?.model).find(Boolean)
  const here = guests.length > 0
  inviteEl.textContent = here ? `Guests are here · ${model || "jev"}` : inviteController ? "Inviting…" : "Invite 8 Ruby guests"
  inviteEl.disabled = here || !!inviteController || !provider.synced
  homeEl.hidden = !here && !inviteController
  const people = [...awareness.getStates().values()].filter((s) => s?.user && !s.guest).length
  statusEl.textContent = `${provider.synced ? "synced" : "connecting"} as ${user.name} · ${documentId.replace(/:cursors$/, "")} · ${people} ${people === 1 ? "person" : "people"}${here ? ` · ${guests.length} guests` : ""}`
}
inviteEl.addEventListener("click", async () => {
  if (inviteController || guestStates().length) return
  inviteStatus.textContent = ""
  party.set("enabled", true)
  const controller = new AbortController()
  inviteController = controller
  renderParty()
  try {
    const response = await fetch(inviteEl.dataset.url, {
      method: "POST",
      headers: { Accept: "text/event-stream", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
      credentials: "same-origin",
      signal: controller.signal,
    })
    if (!response.ok) {
      let message = `The guests could not come (${response.status}).`
      try { message = (await response.json()).error || message } catch { /* not JSON */ }
      throw new Error(message)
    }
    // Under Falcon the stream is the party's lifetime: it runs as long as this
    // page holds it open. Puma answers 204 and runs the party in a thread.
    const reader = response.body?.getReader()
    if (reader) { try { while (!(await reader.read()).done) { /* hold */ } } finally { reader.releaseLock() } }
  } catch (error) {
    if (error.name !== "AbortError") inviteStatus.textContent = error.message
  } finally {
    if (inviteController === controller) inviteController = null
    renderParty()
  }
})
homeEl.addEventListener("click", () => {
  party.set("enabled", false)
  renderParty()
})

window.__yrb = {
  provider, ydoc, signs, party, user, addSign, scale: shown,
  guests: () => guestStates().map((s) => ({ name: s.user.name, trait: s.trait, at: s.at, status: s.status, decision: s.decision })),
  guestTarget: (name) => { const s = guestStates().find((g) => g.user.name === name); if (!s) return null; seat(guestStates()); const p = placeFor(s); return [Math.round(p.x), Math.round(p.y)] },
}

awareness.on("update", renderParty)
party.observe(renderParty)
provider.onStatusChange(renderParty)
// Seed the starter signs only on the FIRST catch-up (whenSynced doesn't
// re-fire on reconnects, so a cleared board stays cleared). Fixed ids, so
// two first opens seed the same three signs rather than six.
provider.whenSynced.then(() => {
  if (signs.size === 0) ydoc.transact(() => { addSign(220, 120, "FREE PIZZA", "s1"); addSign(600, 100, "QUIET ROOM", "s2"); addSign(380, 340, "SF RUBY CONF", "s3") })
  renderParty()
})
renderSigns(); renderParty()
provider.connect()
