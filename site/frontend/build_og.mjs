// Renders og/card.html to public/og.png at 1200x630, the size Open Graph and
// X cards expect. Uses the agent-browser devDependency's headless Chrome.
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const bin = resolve(here, "node_modules/.bin/agent-browser")
const card = `file://${resolve(here, "og/card.html")}`
const out = resolve(here, "../public/og.png")
const env = { ...process.env, AGENT_BROWSER_SESSION: "yrby-og-card" }
const run = (...args) => execFileSync(bin, args, { env, stdio: ["ignore", "pipe", "inherit"] })

try {
  run("set", "viewport", "1200", "630")
  run("open", card)
  run("wait", "1000")
  run("screenshot", out)
  console.log(`built ${out}`)
} finally {
  run("close")
}
