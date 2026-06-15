// In-depth multi-browser concurrent test. Drives real Chrome windows (via
// Playwright) running the actual demo: Tiptap editor plus the @y-rb/actioncable
// provider over @rails/actioncable. Each browser context is an isolated user.
// This exercises the full client stack a real person uses, rather than a
// headless raw-WebSocket simulation.
//
//   bin/rails s -p 3777            (optionally a 2nd process for multi-process)
//   cd frontend && bun multi_browser.mjs
import { chromium } from "playwright-core"
import { serverText as serverTextRead } from "./server_read.mjs"

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const PORTS = (process.env.PORTS || "3777").split(",").map(Number)
const BASE = (port) => `http://localhost:${port}`

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// --- page helpers (run in the browser) -------------------------------------
const synced = (page) => page.evaluate(() => !!(window.__yrb && window.__yrb.provider.synced))
const docXml = (page) => page.evaluate(() => window.__yrb.ydoc.getXmlFragment("default").toString())
const awarenessSize = (page) => page.evaluate(() => window.__yrb.provider.awareness.getStates().size)
const remoteCarets = (page) => page.locator(".collaboration-cursor__caret").count()
const visibleChars = (xml) => xml.replace(/<[^>]+>/g, "").length

const waitSynced = async (page) =>
  page.waitForFunction(() => !!(window.__yrb && window.__yrb.provider.synced), null, { timeout: 20000 })

const waitFor = async (label, pred, ms = 15000) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (await pred()) return true
    await sleep(150)
  }
  check(`TIMEOUT: ${label}`, false)
  return false
}

// All pages report the same document XML (converged), stable across a recheck.
const waitConverged = async (pages, label) => {
  await waitFor(label, async () => {
    const xmls = await Promise.all(pages.map(docXml))
    return xmls.every((x) => x === xmls[0])
  })
  const xmls = await Promise.all(pages.map(docXml))
  return xmls[0]
}

// Move to the end of the doc, start a new paragraph, and type a token with
// real keystrokes, so ProseMirror's input pipeline and Yjs binding are exercised.
const typeNewLine = async (page, token) => {
  await page.evaluate(() => window.__yrb.editor.commands.focus("end"))
  await page.keyboard.press("Enter")
  await page.keyboard.type(token, { delay: 12 })
}

const serverText = (port, room) => serverTextRead(BASE(port), room)

// --- run --------------------------------------------------------------------

const browser = await chromium.launch({ executablePath: CHROME, headless: true })

async function openUser(port, room) {
  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  page.on("pageerror", (e) => console.log(`  [browser error] ${e.message}`))
  await page.goto(`${BASE(port)}/docs/${room}`)
  await waitSynced(page)
  return { ctx, page, port }
}

try {
  // ===== Scenario 1: four browsers, sequential round-trip =================
  console.log("\n--- Scenario 1: four real browsers, full round-trip ---")
  const room1 = `mb1-${process.pid}`
  const users = []
  for (let i = 0; i < 4; i++) users.push(await openUser(PORTS[i % PORTS.length], room1))
  const pages = users.map((u) => u.page)
  check("all four browsers connected and synced", (await Promise.all(pages.map(synced))).every(Boolean))

  const tokens = ["alpha-line", "bravo-line", "charlie-line", "delta-line"]
  for (let i = 0; i < pages.length; i++) {
    await typeNewLine(pages[i], tokens[i])
    await waitFor(`all browsers see "${tokens[i]}"`, async () =>
      (await Promise.all(pages.map(docXml))).every((x) => x.includes(tokens[i])))
  }
  const conv1 = await waitConverged(pages, "all four browsers converged")
  check("every browser has identical document", (await Promise.all(pages.map(docXml))).every((x) => x === conv1))
  check("every typed line is present", tokens.every((t) => conv1.includes(t)))
  const srv1 = await serverText(users[0].port, room1)
  check("server-side read matches the browsers", tokens.every((t) => srv1.includes(t)))

  // ===== Scenario 2: presence / live cursors ==============================
  console.log("\n--- Scenario 2: presence & cursors across browsers ---")
  await waitFor("every browser sees all 4 presences", async () =>
    (await Promise.all(pages.map(awarenessSize))).every((n) => n === 4))
  check("awareness shows 4 users in every browser", (await Promise.all(pages.map(awarenessSize))).every((n) => n === 4))
  // After everyone has typed, remote carets should be rendered.
  const caretCounts = await Promise.all(pages.map(remoteCarets))
  check("remote collaboration cursors are rendered", caretCounts.every((c) => c >= 1))

  // ===== Scenario 3: late joiner ==========================================
  console.log("\n--- Scenario 3: a late browser joins ---")
  const late = await openUser(PORTS[0], room1)
  const lateOk = await waitFor("late browser has all lines", async () => {
    const x = await docXml(late.page)
    return tokens.every((t) => x.includes(t))
  })
  check("late joiner received the whole document", lateOk)
  users.push(late)
  pages.push(late.page)

  // ===== Scenario 4: reload / reconnect ===================================
  console.log("\n--- Scenario 4: reload (reconnect) a browser ---")
  await users[0].page.reload()
  await waitSynced(users[0].page)
  await waitFor("reloaded browser restored its content", async () => {
    const x = await docXml(users[0].page)
    return tokens.every((t) => x.includes(t))
  })
  check("reloaded browser re-synced the full document", true)
  await sleep(600) // let the freshly reconnected provider settle before editing
  await typeNewLine(users[0].page, "after-reload")
  await waitFor("others see the post-reload edit", async () =>
    (await docXml(users[1].page)).includes("after-reload"))
  check("reloaded browser can edit and others receive it", (await docXml(users[1].page)).includes("after-reload"))

  // ===== Scenario 5: concurrent storm (max contention) ===================
  console.log("\n--- Scenario 5: all browsers type concurrently ---")
  const room5 = `mb5-${process.pid}`
  const stormUsers = []
  for (let i = 0; i < 4; i++) stormUsers.push(await openUser(PORTS[i % PORTS.length], room5))
  const stormPages = stormUsers.map((u) => u.page)
  await Promise.all(stormPages.map(synced))

  // Each browser types a burst at the same time. Concurrent inserts interleave
  // (YATA) so we assert convergence + character conservation, not substrings.
  const BURST = 20
  const bursts = ["W", "X", "Y", "Z"].map((c) => c.repeat(BURST))
  await Promise.all(stormPages.map(async (p, i) => {
    await p.evaluate(() => window.__yrb.editor.commands.focus("end"))
    await p.keyboard.press("Enter")
    await p.keyboard.type(bursts[i], { delay: 8 })
  }))

  const conv5 = await waitConverged(stormPages, "all browsers converged after the storm")
  check("every browser identical after concurrent storm",
    (await Promise.all(stormPages.map(docXml))).every((x) => x === conv5))
  const expectedChars = BURST * 4 // 4 bursts; the 4 Enters add empty paragraphs, not chars
  check(`characters conserved (${visibleChars(conv5)} >= ${expectedChars})`, visibleChars(conv5) >= expectedChars)
  const srv5 = await serverText(stormUsers[0].port, room5)
  check("server state converged with the browsers",
    srv5.replace(/\s/g, "").length === visibleChars(conv5))

  for (const u of [...users, ...stormUsers]) await u.ctx.close()
} finally {
  await browser.close()
}

console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: real browsers sync correctly through the yrb-lite server")
process.exit(0)
