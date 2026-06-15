// Four real Chrome browsers typing into the same document at the same time.
// Each browser types its own digit so we can account for every keystroke per
// contributor and confirm nothing is lost under simultaneous typing.
//
//   bin/rails s -p 3777          (or two processes; pass PORTS=3777,3778)
//   cd frontend && bun four_browsers.mjs
import { chromium } from "playwright-core"
import { serverText } from "./server_read.mjs"

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const PORTS = (process.env.PORTS || "3777").split(",").map(Number)
const PER = Number(process.env.PER || 40) // keystrokes per browser per round
const BASE = (port) => `http://localhost:${port}`

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const docXml = (page) => page.evaluate(() => window.__yrb.ydoc.getXmlFragment("default").toString())
const awarenessSize = (page) => page.evaluate(() => window.__yrb.provider.awareness.getStates().size)
const visibleText = (xml) => xml.replace(/<[^>]+>/g, "")
const countChar = (s, c) => s.split(c).length - 1

const waitSynced = (page) =>
  page.waitForFunction(() => !!(window.__yrb && window.__yrb.provider.synced), null, { timeout: 20000 })

const waitFor = async (label, pred, ms = 20000) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (await pred()) return true
    await sleep(150)
  }
  check(`TIMEOUT: ${label}`, false)
  return false
}

const waitConverged = async (pages) => {
  await waitFor("all four browsers converged", async () => {
    const xs = await Promise.all(pages.map(docXml))
    return xs.every((x) => x === xs[0])
  })
  return (await Promise.all(pages.map(docXml)))[0]
}

const browser = await chromium.launch({ executablePath: CHROME, headless: true })
const DIGITS = ["1", "2", "3", "4"]
let errors = 0

try {
  const room = `four-${process.pid}`
  const ctxs = []
  const pages = []
  for (let i = 0; i < 4; i++) {
    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    page.on("pageerror", (e) => { errors++; console.log(`  [browser error] ${e.message}`) })
    await page.goto(`${BASE(PORTS[i % PORTS.length])}/docs/${room}`)
    await waitSynced(page)
    ctxs.push(ctx)
    pages.push(page)
  }
  const portOf = (i) => PORTS[i % PORTS.length]
  check("all 4 browsers connected and synced", true)
  await waitFor("all 4 presences visible", async () =>
    (await Promise.all(pages.map(awarenessSize))).every((n) => n === 4))
  check("awareness shows 4 live users", (await Promise.all(pages.map(awarenessSize))).every((n) => n === 4))

  // ---- Round 1: all four type at the end, simultaneously -----------------
  console.log(`\n--- Round 1: 4 browsers each type '${PER}' chars at once ---`)
  await Promise.all(pages.map(async (p, i) => {
    await p.evaluate(() => window.__yrb.editor.commands.focus("end"))
    await p.keyboard.type(DIGITS[i].repeat(PER), { delay: 10 })
  }))
  const c1 = await waitConverged(pages)
  check("every browser identical after simultaneous typing",
    (await Promise.all(pages.map(docXml))).every((x) => x === c1))
  const t1 = visibleText(c1)
  for (let i = 0; i < 4; i++) {
    check(`browser ${i + 1}: all ${PER} of '${DIGITS[i]}' survived (got ${countChar(t1, DIGITS[i])})`,
      countChar(t1, DIGITS[i]) === PER)
  }
  check(`total characters conserved (${t1.length} == ${PER * 4})`, t1.length === PER * 4)

  // ---- Round 2: all four type at the same position (max contention) ------
  console.log("\n--- Round 2: 4 browsers type at the document start, at once ---")
  await Promise.all(pages.map(async (p, i) => {
    await p.evaluate(() => window.__yrb.editor.commands.focus("start"))
    await p.keyboard.type(DIGITS[i].repeat(PER), { delay: 8 })
  }))
  const c2 = await waitConverged(pages)
  check("every browser identical after same-position storm",
    (await Promise.all(pages.map(docXml))).every((x) => x === c2))
  const t2 = visibleText(c2)
  for (let i = 0; i < 4; i++) {
    check(`browser ${i + 1}: all ${PER * 2} of '${DIGITS[i]}' survived (got ${countChar(t2, DIGITS[i])})`,
      countChar(t2, DIGITS[i]) === PER * 2)
  }
  check(`total characters conserved (${t2.length} == ${PER * 8})`, t2.length === PER * 8)

  // ---- Server-side view agrees ------------------------------------------
  const srv = await serverText(BASE(portOf(0)), room)
  for (let i = 0; i < 4; i++) {
    check(`server state has all of browser ${i + 1}'s '${DIGITS[i]}'`, countChar(srv, DIGITS[i]) === PER * 2)
  }
  check("no uncaught browser errors during the storm", errors === 0)

  for (const c of ctxs) await c.close()
} finally {
  await browser.close()
}

console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: four browsers typing at once: full convergence, every keystroke accounted for")
process.exit(0)
