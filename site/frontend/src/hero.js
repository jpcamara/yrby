// The home page hero: a replay of two people editing one document, with the
// Rails side of the sync underneath. It's a scripted animation, not a live
// room (the demos are live), so it needs no cable and costs the server nothing.
//
// Markup (pages/index.html.erb) renders the finished state, so a visitor
// without JavaScript or with reduced motion sees a complete picture.

const PEERS = {
  you: { label: "you", color: "var(--color-peer-you)" },
  ada: { label: "ada", color: "var(--color-peer-ada)" },
}
const START = "Launch checklist\n"
const TITLE_END = "Launch checklist".length
const SCRIPT = {
  you: [{ to: "title" }, { type: " for Friday" }, { wait: 18 }, { to: "end" }, { type: "\n• Publish yrby-client 0.6.0" }],
  ada: [{ to: "end" }, { type: "• Tag the GitHub release" }],
}
const TICK_MS = 85
const PAUSE_TICKS = 50
const UPDATE_CHARS = 5
const LOG_LINES = 4

const hero = document.querySelector("[data-hero]")
if (hero && !matchMedia("(prefers-reduced-motion: reduce)").matches) run(hero)

function run(root) {
  const panes = [...root.querySelectorAll("[data-pane]")]
  const log = root.querySelector("[data-log]")
  const rows = root.querySelector("[data-rows]")
  const read = root.querySelector("[data-read]")
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
      pending: { you: 0, ada: 0 },
      updates: 0,
      log: [],
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
      flush(who)
      sim.carets[who] = action.to === "title" ? TITLE_END : sim.text.length
      progress.i++
    } else if (action.wait) {
      if (++progress.c >= action.wait) Object.assign(progress, { i: progress.i + 1, c: 0 })
    } else {
      const at = sim.carets[who]
      sim.text = sim.text.slice(0, at) + action.type[progress.c] + sim.text.slice(at)
      for (const other of Object.keys(sim.carets)) {
        if (other !== who && sim.carets[other] >= at) sim.carets[other]++
      }
      sim.carets[who] = at + 1
      sim.pending[who]++
      progress.c++
      if (sim.pending[who] >= UPDATE_CHARS) flush(who)
      if (progress.c >= action.type.length) {
        flush(who)
        Object.assign(progress, { i: progress.i + 1, c: 0 })
      }
    }
  }

  // One Yjs update per few characters, the way an editor batches keystrokes.
  function flush(who) {
    if (sim.pending[who] === 0) return
    sim.updates++
    sim.log = [...sim.log, { n: sim.updates, who, chars: sim.pending[who] }].slice(-LOG_LINES)
    sim.pending[who] = 0
  }

  function draw() {
    for (const pane of panes) drawPane(pane, pane.dataset.pane)
    rows.textContent = sim.updates
    read.textContent = `"${sim.text.replaceAll("\n", "\\n")}"`
    log.replaceChildren(...sim.log.map((entry, index) => {
      const line = document.createElement("li")
      if (index === sim.log.length - 1) line.className = "latest"
      const who = document.createElement("span")
      who.style.color = entry.who === "you" ? "#8fb0ff" : "#e8b05c"
      who.textContent = entry.who
      line.append(who, ` update #${entry.n} · ${entry.chars} chars → recorded → ack`)
      return line
    }))
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
