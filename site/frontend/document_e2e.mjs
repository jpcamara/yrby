// Execute the record-backed quickstart in two real browsers against the site.
import assert from "node:assert/strict"
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { fileURLToPath } from "node:url"

const exec = promisify(execFile)
const base = process.env.BASE_URL || `http://127.0.0.1:${process.env.PORT || 3888}`
const sessions = ["yrby-doc-example-a", "yrby-doc-example-b"]
const [a, b] = sessions
const marker = `example-${Date.now()}`
const ab = async (session, ...args) => {
  const { stdout } = await exec(process.env.AB_BIN || fileURLToPath(new URL("./node_modules/.bin/agent-browser", import.meta.url)), args, {
    env: { ...process.env, AGENT_BROWSER_SESSION: session }, timeout: 30000,
  })
  return stdout.trim()
}
const js = async (session, source) => JSON.parse(await ab(session, "eval", source))
const wait = async (label, fn) => {
  const deadline = Date.now() + 20000
  while (Date.now() < deadline) {
    if (await fn()) { console.log(`ok: ${label}`); return }
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  throw new Error(`Timed out: ${label}`)
}
const element = 'document.querySelector("yrby-document")'
const ready = (s) => js(s, `!!(${element}?.provider?.synced && document.querySelector(".cm-content"))`)
const text = (s) => js(s, `${element}.doc.getText("content").toString()`)
const saved = (s) => js(s, 'fetch("/examples/document/stored").then(r => r.json()).then(r => r.body || "")')

try {
  for (const session of sessions) {
    await ab(session, "open", `${base}/examples/document`)
    await ab(session, "set", "viewport", "1280", "900")
    await wait(`${session} mounts after sync`, () => ready(session))
  }
  await ab(a, "click", ".cm-content")
  await ab(a, "keyboard", "type", `${marker} `)
  await wait("typing reaches the peer and Ruby read-back", async () =>
    (await text(b)).includes(marker) && (await saved(a)).includes(marker))
  await ab(a, "click", "#read-document")
  await wait("the read panel displays the stored text", () => js(a,
    `document.querySelector("#stored-document").textContent.includes(${JSON.stringify(marker)})`))
  await wait("all local edits acknowledged", () => js(a, `!${element}.session.hasPending`))

  await js(a, `window.exampleElement = ${element}; window.oldSession = exampleElement.session;
    window.oldDoc = exampleElement.doc; window.exampleParent = exampleElement.parentNode;
    exampleElement.remove(); true`)
  await wait("removal destroys the editor and releases a clean session", () => js(a,
    'oldSession.state === "closed" && !exampleElement.querySelector(".cm-content")'))
  await js(a, "exampleParent.append(exampleElement); true")
  await wait("clean remount reconstructs saved content", async () =>
    (await ready(a)) && (await text(a)).includes(marker))
  assert.equal(await js(a, "exampleElement.doc !== oldDoc"), true)
  console.log("ok: clean remount does not promise identical Y.Doc")

  await js(a, "window.pendingSession = exampleElement.session; pendingSession.store.suspend(); true")
  await ab(a, "click", ".cm-content")
  await ab(a, "keyboard", "type", `${marker}-pending `)
  await wait("offline typing remains unacknowledged", () => js(a, "pendingSession.hasPending"))
  await js(a, "exampleElement.remove(); true")
  await wait("detached editor cleaned up while pending session drains", () => js(a,
    'pendingSession.state === "draining" && !exampleElement.querySelector(".cm-content")'))
  await js(a, "pendingSession.store.resume(); true")
  await wait("detached pending work reaches Ruby and closes after ack", async () =>
    (await saved(b)).includes(`${marker}-pending`) &&
    (await js(a, 'pendingSession.state === "closed"')))
  await js(a, "exampleParent.append(exampleElement); true")
  await wait("remount includes delivered offline edits", async () =>
    (await ready(a)) && (await text(a)).includes(`${marker}-pending`))

  await ab(a, "screenshot", process.env.SCREENSHOT || "/tmp/yrby-document-example.png")
  for (const session of sessions) {
    assert.equal(await js(session, "document.documentElement.scrollWidth <= innerWidth"), true)
    const errors = await ab(session, "errors")
    assert.ok(!errors || /No (errors|page errors)/i.test(errors), errors)
  }
  console.log("ok: record-backed example browser checks passed")
} catch (error) {
  for (const session of sessions) {
    console.error(session, await js(session,
      '({url:location.href, title:document.title, status:document.querySelector("#document-status")?.textContent})').catch(() => null))
    console.error(await ab(session, "errors").catch(() => "Browser unavailable"))
  }
  throw error
} finally {
  await Promise.allSettled(sessions.map(session => ab(session, "close")))
}
