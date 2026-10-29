// The home page hero: a replay of two people editing one document. It's a
// scripted animation (the demos are the live version), so it doesn't open a
// cable or use the server.
//
// pages/index.html.erb renders the finished state, so a visitor without
// JavaScript or with reduced motion sees the whole picture.

const PEERS = {
  you: { label: "you", color: "var(--color-peer-you)" },
  ada: { label: "ada", color: "var(--color-peer-ada)" },
}
const START = "Writing together\n"
const TITLE_END = "Writing together".length
// "you" moves to the end only after ada finishes her line. Two carets at the
// same spot would interleave their letters. A real CRDT does that too, but it
// makes the demo confusing.
const SCRIPT = {
  you: [{ to: "title" }, { type: " in Rails" }, { after: "ada" }, { to: "end" }, { type: "\n• Saved before anyone sees them" }],
  ada: [{ to: "end" }, { type: "• Edits merge without conflicts" }],
}
const TICK_MS = 85
const PAUSE_TICKS = 50

const hero = document.querySelector("[data-hero]")
if (hero && !matchMedia("(prefers-reduced-motion: reduce)").matches) run(hero)

function run(root) {
  const panes = [...root.querySelectorAll("[data-pane]")]
  let sim = fresh()

  setInterval(() => {
    if (document.hidden) return
    tick()
    draw()
  }, TICK_MS)

  function fresh() {
    return {
      text: START,
      carets: { you: TITLE_END, ada: START.length },
      progress: { you: { i: 0, c: 0 }, ada: { i: 0, c: 0 } },
      pause: 0,
    }
  }

  function tick() {
    if (sim.pause > 0) {
      if (--sim.pause === 0) sim = fresh()
      return
    }
    const active = Object.keys(SCRIPT).filter(who => sim.progress[who].i < SCRIPT[who].length)
    if (active.length === 0) {
      sim.pause = PAUSE_TICKS
      return
    }
    step(active[Math.floor(Math.random() * active.length)])
  }

  function step(who) {
    const progress = sim.progress[who]
    const action = SCRIPT[who][progress.i]
    if (action.to) {
      sim.carets[who] = action.to === "title" ? TITLE_END : sim.text.length
      progress.i++
    } else if (action.after) {
      if (sim.progress[action.after].i >= SCRIPT[action.after].length) progress.i++
    } else {
      const at = sim.carets[who]
      sim.text = sim.text.slice(0, at) + action.type[progress.c] + sim.text.slice(at)
      for (const other of Object.keys(sim.carets)) {
        if (other !== who && sim.carets[other] >= at) sim.carets[other]++
      }
      sim.carets[who] = at + 1
      if (++progress.c >= action.type.length) Object.assign(progress, { i: progress.i + 1, c: 0 })
    }
  }

  function draw() {
    for (const pane of panes) drawPane(pane, pane.dataset.pane)
  }

  // The document with both carets placed in it. Each window shows its own
  // caret bare and the other person's with a name flag.
  function drawPane(pane, viewer) {
    const carets = Object.entries(sim.carets).sort((a, b) => a[1] - b[1])
    const nodes = []
    let at = 0
    for (const [who, position] of carets) {
      if (position > at) nodes.push(document.createTextNode(sim.text.slice(at, position)))
      nodes.push(caret(who, who !== viewer))
      at = position
    }
    if (at < sim.text.length) nodes.push(document.createTextNode(sim.text.slice(at)))
    pane.replaceChildren(...nodes)
  }

  function caret(who, flagged) {
    const mark = document.createElement("span")
    mark.className = "hero-caret"
    mark.style.setProperty("--peer", PEERS[who].color)
    if (flagged) {
      const flag = document.createElement("span")
      flag.className = "hero-flag"
      flag.textContent = PEERS[who].label
      mark.append(flag)
    }
    return mark
  }
}
