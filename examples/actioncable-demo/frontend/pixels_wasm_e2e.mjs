// Actual Chrome input against the ordinary yrby-client and the Ruby WASM peer.
//   BASE=http://127.0.0.1:3778 node pixels_wasm_e2e.mjs
//   LIVE_ARTIST=1 BASE=http://127.0.0.1:3778 node pixels_wasm_e2e.mjs
// Build the optional experiment assets first. LIVE_ARTIST needs a configured
// server-side model key and makes paid calls; the default path does not.
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { resolve, dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const BASE = (process.env.BASE || "http://127.0.0.1:3778").replace(/\/$/, "")
const room = process.env.ROOM || `pixels-wasm-test-${Date.now()}`
const LIVE = process.env.LIVE_ARTIST === "1"
const shots = process.env.SHOTS || "/tmp"
const suffix = `${process.pid}-${Date.now()}`
const normal = `pixel-js-${suffix}`
const ruby = `pixel-wasm-${suffix}`
const sessions = [normal, ruby]
const normalURL = `${BASE}/docs/${encodeURIComponent(room)}/pixels`
const rubyURL = `${normalURL}/ruby`
const colors = ["1d2038", "38415d", "697a91", "b4c3ce", "f6eedb", "ffffff", "c85b50", "f27c63", "f6bb6a", "ffe7a0", "447a70", "78b38b", "36699b", "66a4cc", "9b78aa", "d69bbd"]
const rubyStatus = "JSON.parse(window.__rubyPixel.client.getStatus())"
const rubyMaps = "Object.fromEntries([\"scene\",\"pixels\",\"artist_pixels\",\"mural\"].map(name=>[name,JSON.parse(window.__rubyPixel.client.map(name).readJSON())]))"
const normalMaps = "({scene:window.__yrb.scene.toJSON(),pixels:window.__yrb.pixels.toJSON(),artist_pixels:window.__yrb.artistPixels.toJSON(),mural:window.__yrb.mural.toJSON()})"
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
let checks = 0
let artistInvited = false
let suitePassed = false

function ab(session, ...args) {
  const output = execFileSync(AB, ["--session", session, "--json", ...args], {
    encoding: "utf8", timeout: 45_000, stdio: ["ignore", "pipe", "pipe"],
  })
  const result = JSON.parse(output)
  assert.ok(result.success, result.error || output)
  return result.data
}
const evaluate = (session, expression) => ab(session, "eval", expression).result
const maps = (session) => evaluate(session, session === ruby ? rubyMaps : normalMaps)
const status = () => evaluate(ruby, rubyStatus)
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
  return value
}
const serializedMaps = (session) => JSON.stringify(canonical(maps(session)))
function check(label, condition) {
  assert.ok(condition, label)
  console.log(`ok ${++checks}: ${label}`)
}
async function until(label, predicate, timeout = 20_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (predicate()) return
    await sleep(180)
  }
  let diagnostic
  try { diagnostic = evaluate(ruby, "({ready:window.__rubyPixel?.ready,status:window.__rubyPixel?.client.getStatus(),error:document.querySelector('#wasm-error')?.textContent})") }
  catch { diagnostic = "Ruby page unavailable" }
  throw new Error(`Timed out: ${label}; ${JSON.stringify(diagnostic)}`)
}
const waitFor = (session, expression, label, timeout) => until(label, () => evaluate(session, expression), timeout)
const syncedNormal = () => waitFor(normal, "!!window.__yrb?.provider.synced", "ordinary client sync")
const syncedRuby = () => waitFor(ruby, `!!window.__rubyPixel?.ready && ${rubyStatus}.synced && document.querySelector('#mural-canvas').dataset.rubyRendered==='true'`, "Ruby runtime and document sync", 90_000)
const converge = () => until("all four shared maps converge", () => serializedMaps(normal) === serializedMaps(ruby))
function choose(session, color) {
  ab(session, "click", `#palette .swatch:nth-child(${color + 1})`)
}
function stroke(session, from, to = from) {
  const selector = "#mural-canvas"
  const rect = evaluate(session, `(() => {const r=document.querySelector('${selector}').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()`)
  const point = ([x, y]) => [String(Math.round(rect.x + (x + .5) * rect.width / 64)), String(Math.round(rect.y + (y + .5) * rect.height / 32))]
  ab(session, "mouse", "move", ...point(from))
  ab(session, "mouse", "down")
  try { if (from[0] !== to[0] || from[1] !== to[1]) ab(session, "mouse", "move", ...point(to)) }
  finally { ab(session, "mouse", "up") }
}
async function painted(session, expected, label) {
  const expression = session === ruby ? rubyMaps : normalMaps
  await waitFor(session, `Object.entries(${JSON.stringify(expected)}).every(([key,color])=>${expression}.pixels[key]===color)`, label)
}
async function rendered(points, label) {
  const expected = points.map(([x, y, color]) => ({ x, y, rgba: [...colors[color].match(/../g).map(value => parseInt(value, 16)), 255].join(",") }))
  await waitFor(ruby, `(() => {
    const c=document.querySelector('#mural-canvas'), context=c.getContext('2d');
    return ${JSON.stringify(expected)}.every(({x,y,rgba})=>[...context.getImageData(Math.floor((x+.5)*c.width/64),Math.floor((y+.5)*c.height/32),1,1).data].join(',')===rgba);
  })()`, label)
}

console.log(`# Pixel Bay Ruby WASM ${room} (${LIVE ? "live artist" : "human peers; no model calls"})`)
mkdirSync(shots, { recursive: true })
try {
  ab(normal, "set", "viewport", "1440", "960")
  ab(normal, "open", normalURL)
  await syncedNormal()
  ab(ruby, "set", "viewport", "1440", "960")
  ab(ruby, "open", rubyURL)
  await syncedRuby()
  const engine = evaluate(ruby, 'window.__rubyPixel.vm.eval(\'RUBY_ENGINE + "@" + RUBY_PLATFORM\').toString()')
  check("the browser executes actual CRuby on WebAssembly", /^ruby@.*wasm/i.test(engine))
  console.log(`runtime: ${engine}`)
  check("Ruby builds all 16 palette buttons", evaluate(ruby, "document.querySelectorAll('#palette .swatch').length===16"))
  check("both engines receive the complete 2048-pixel scene", Object.keys(maps(normal).scene).length === 2048 && Object.keys(maps(ruby).scene).length === 2048)
  await converge()
  check("Yjs and Yrs begin with identical scene, human, artist and mural maps", true)
  const sceneColor = maps(ruby).scene["32,0"]
  await rendered([[32, 0, sceneColor]], "Ruby renders the received scene")
  check("Ruby draws actual received scene colors on its canvas", true)
  check("the normal studio remains a prominent same-room option", evaluate(ruby, `!![...document.querySelectorAll('a[target="_blank"]')].find(a=>a.href===${JSON.stringify(normalURL)} && a.textContent.includes('Open main studio') && a.rel.includes('noopener'))`))

  // Exercise the reusable Ruby client, not just the Pixel Bay facade. These
  // roots share the document but have no effect on the scene or artist inputs.
  const genericRoots = { map: "wasm-e2e-map", text: "wasm-e2e-text", array: "wasm-e2e-array" }
  const rubyWrite = `
    doc = PIXEL_BROWSER.client.doc
    map = doc.map(${JSON.stringify(genericRoots.map)})
    text = doc.text(${JSON.stringify(genericRoots.text)})
    array = doc.array(${JSON.stringify(genericRoots.array)})
    doc.transaction do
      map["metadata"] = { "source" => "ruby", "nested" => [nil, true, 7] }
      map["nullable"] = nil
      text.insert(0, "A💎B")
      array.insert(0, "ruby", { "votes" => 2 })
    end
    JSON.generate({ "map" => map.to_h, "text" => text.to_s, "array" => array.to_a,
      "nullable_present" => map.key?("nullable"), "missing_present" => map.key?("missing") })
  `
  const rubyValue = JSON.parse(evaluate(ruby, `window.__rubyPixel.vm.eval(${JSON.stringify(rubyWrite)}).toString()`))
  check("Ruby generic map, text and array wrappers preserve nested JSON and nil", rubyValue.nullable_present && !rubyValue.missing_present && rubyValue.map.nullable === null && rubyValue.map.metadata.nested[0] === null && rubyValue.map.metadata.nested[1] === true && rubyValue.text === "A💎B" && rubyValue.array[1].votes === 2)
  await waitFor(normal, `(() => {
    const doc=window.__yrb.ydoc;
    return doc.getMap(${JSON.stringify(genericRoots.map)}).get('metadata')?.source==='ruby' &&
      doc.getText(${JSON.stringify(genericRoots.text)}).toString()==='A💎B' &&
      doc.getArray(${JSON.stringify(genericRoots.array)}).toJSON()[1]?.votes===2;
  })()`, "generic Ruby roots reach Yjs")
  check("generic Ruby shared types interoperate with the normal Yjs document", true)
  evaluate(normal, `(() => {
    const doc=window.__yrb.ydoc;
    const map=doc.getMap(${JSON.stringify(genericRoots.map)}), text=doc.getText(${JSON.stringify(genericRoots.text)}), array=doc.getArray(${JSON.stringify(genericRoots.array)});
    doc.transact(()=>{map.set('from_js',true);text.insert(3,'!');array.insert(1,['javascript'])});
  })()`)
  const rubyRead = `
    doc = PIXEL_BROWSER.client.doc
    JSON.generate({ "map" => doc.map(${JSON.stringify(genericRoots.map)}).to_h,
      "text" => doc.text(${JSON.stringify(genericRoots.text)}).to_s,
      "array" => doc.array(${JSON.stringify(genericRoots.array)}).to_a })
  `
  await waitFor(ruby, `(() => {
    const result=JSON.parse(window.__rubyPixel.vm.eval(${JSON.stringify(rubyRead)}).toString());
    return result.map.from_js===true && result.text==='A💎!B' && result.array[1]==='javascript';
  })()`, "Yjs generic edits arrive through Ruby wrappers")
  check("Ruby reads remote map, array and UTF-16 text changes through its public API", true)
  const rubyDelete = `
    doc = PIXEL_BROWSER.client.doc
    map = doc.map(${JSON.stringify(genericRoots.map)})
    text = doc.text(${JSON.stringify(genericRoots.text)})
    array = doc.array(${JSON.stringify(genericRoots.array)})
    doc.transaction do
      map.delete("nullable")
      text.delete(1, 2)
      array.delete(0)
    end
    JSON.generate({ "map" => map.to_h, "text" => text.to_s, "array" => array.to_a })
  `
  const deleted = JSON.parse(evaluate(ruby, `window.__rubyPixel.vm.eval(${JSON.stringify(rubyDelete)}).toString()`))
  await waitFor(normal, `window.__yrb.ydoc.getText(${JSON.stringify(genericRoots.text)}).toString()==='A!B' && window.__yrb.ydoc.getArray(${JSON.stringify(genericRoots.array)}).toJSON()[0]==='javascript' && !window.__yrb.ydoc.getMap(${JSON.stringify(genericRoots.map)}).has('nullable')`, "Ruby generic deletions synchronize")
  check("Ruby deletes map entries, array elements and a two-unit emoji consistently with Yjs", !Object.hasOwn(deleted.map, "nullable") && deleted.text === "A!B" && deleted.array[0] === "javascript")

  ab(normal, "fill", "#your-name", "JavaScript painter")
  ab(normal, "press", "Tab")
  ab(ruby, "fill", "#your-name", "Ruby painter")
  ab(ruby, "press", "Tab")
  await waitFor(normal, "[...window.__yrb.provider.awareness.getStates().values()].some(p=>p.user?.name==='Ruby painter')", "Ruby presence in ordinary client")
  await waitFor(ruby, `${rubyStatus}.peers.some(p=>p.user?.name==='JavaScript painter')`, "ordinary client presence in Ruby")
  check("names and live presence interoperate in both directions", true)

  choose(ruby, 7)
  stroke(ruby, [2, 2], [7, 2])
  await painted(normal, Object.fromEntries([2, 3, 4, 5, 6, 7].map(x => [`${x},2`, 7])), "Ruby pointer stroke reaches JavaScript")
  ab(ruby, "press", "ArrowDown")
  ab(ruby, "press", "Enter")
  await painted(normal, { "7,3": 7 }, "Ruby keyboard paint reaches JavaScript")
  await rendered([[2, 2, 7], [5, 2, 7], [7, 3, 7]], "Ruby renders its input")
  check("Ruby pointer interpolation and keyboard paint reach the ordinary client", Object.keys(maps(ruby).pixels).length >= 7)

  choose(normal, 12)
  stroke(normal, [10, 4])
  ab(normal, "press", "ArrowRight")
  ab(normal, "press", "Enter")
  await painted(ruby, { "10,4": 12, "11,4": 12 }, "JavaScript pointer and keyboard strokes reach Ruby")
  await rendered([[10, 4, 12], [11, 4, 12]], "Ruby paints received JavaScript updates")
  check("ordinary pointer and keyboard input appears as the right Ruby-rendered colors", true)
  await converge()

  // Each pointer gesture is one history item, even when its line contains many
  // pixels. Later remote writes must survive local undo and redo.
  choose(ruby, 6)
  stroke(ruby, [27, 11], [31, 11])
  stroke(ruby, [27, 12], [29, 12])
  await converge()
  choose(normal, 9)
  stroke(normal, [29, 11])
  stroke(normal, [35, 12])
  await converge()
  ab(ruby, "click", "#undo-stroke")
  await converge()
  let history = maps(ruby).pixels
  check("undo removes an entire pointer gesture and leaves the preceding stroke", [27, 28, 29].every(x => history[`${x},12`] === undefined) && [27, 28, 30, 31].every(x => history[`${x},11`] === 6))
  ab(ruby, "press", "Control+z")
  await converge()
  history = maps(ruby).pixels
  check("undo preserves a remote overwrite and a remote independent cell", [27, 28, 30, 31].every(x => history[`${x},11`] === undefined) && history["29,11"] === 9 && history["35,12"] === 9)
  ab(ruby, "press", "Control+Shift+z")
  ab(ruby, "press", "Control+Shift+z")
  await converge()
  history = maps(ruby).pixels
  check("keyboard redo restores both local gestures without replacing the remote winner", [27, 28, 30, 31].every(x => history[`${x},11`] === 6) && [27, 28, 29].every(x => history[`${x},12`] === 6) && history["29,11"] === 9 && history["35,12"] === 9)

  // A deterministic artist-layer fixture exercises rendering and erasing
  // without buying a model call. LIVE_ARTIST below separately proves real AI.
  const eraserPoint = [44, 2], eraserKey = eraserPoint.join(",")
  evaluate(normal, `window.__yrb.artistPixels.set(${JSON.stringify(eraserKey)},8)`)
  await converge()
  await rendered([[...eraserPoint, 8]], "Ruby renders the seeded artist pixel")
  ab(ruby, "click", "#eraser-tool")
  check("the eraser button exposes its selected state", evaluate(ruby, "document.querySelector('#eraser-tool').getAttribute('aria-pressed')==='true' && document.querySelector('#brush-tool').getAttribute('aria-pressed')==='false'"))
  stroke(ruby, eraserPoint)
  await converge()
  const erasedColor = maps(ruby).scene[eraserKey]
  check("Ruby eraser restores the scene with a protected human override", maps(ruby).pixels[eraserKey] === erasedColor)
  evaluate(normal, `window.__yrb.artistPixels.set(${JSON.stringify(eraserKey)},9)`)
  await converge()
  await rendered([[...eraserPoint, erasedColor]], "erased region remains protected from later artist paint")
  check("later artist updates do not repaint an erased human pixel", true)
  ab(ruby, "click", "#undo-stroke")
  await converge()
  await rendered([[...eraserPoint, 9]], "undoing eraser reveals the latest artist layer")
  check("undoing erase removes the human override and reveals current artist paint", maps(ruby).pixels[eraserKey] === undefined && maps(ruby).artist_pixels[eraserKey] === 9)
  ab(ruby, "press", "Control+Shift+z")
  await converge()
  await rendered([[...eraserPoint, erasedColor]], "redoing erase restores protection")
  check("redo restores the protected erased cell", maps(ruby).pixels[eraserKey] === erasedColor)
  ab(ruby, "click", "#undo-stroke")
  evaluate(normal, `window.__yrb.artistPixels.delete(${JSON.stringify(eraserKey)})`)
  ab(ruby, "click", "#brush-tool")
  await converge()

  evaluate(ruby, "window.__testGridOff=document.querySelector('#mural-canvas').toDataURL()")
  ab(ruby, "click", "#grid-tool")
  await waitFor(ruby, "document.querySelector('#grid-tool').getAttribute('aria-pressed')==='true' && document.querySelector('#mural-canvas').toDataURL()!==window.__testGridOff", "grid changes actual canvas pixels")
  check("grid toggle draws visible grid lines and updates accessible state", true)
  ab(ruby, "click", "#grid-tool")
  await waitFor(ruby, "document.querySelector('#grid-tool').getAttribute('aria-pressed')==='false' && document.querySelector('#mural-canvas').toDataURL()===window.__testGridOff", "grid removal restores canvas exactly")
  check("hiding the grid restores the same pixel image", true)

  const beforeTextKeys = JSON.stringify(canonical(maps(ruby).pixels))
  ab(ruby, "click", "#artist-brief")
  for (const key of ["e", "b", "Enter", "ArrowDown", "Control+z"]) ab(ruby, "press", key)
  check("editor typing ignores paint, tool and undo keyboard shortcuts", JSON.stringify(canonical(maps(ruby).pixels)) === beforeTextKeys && evaluate(ruby, "document.querySelector('#brush-tool').getAttribute('aria-pressed')==='true'"))
  ab(ruby, "fill", "#artist-brief", "Ruby asks for a tiny balloon over the bay.")
  ab(ruby, "press", "Tab")
  await waitFor(normal, "window.__yrb.mural.get('brief')==='Ruby asks for a tiny balloon over the bay.' && document.querySelector('#artist-brief').value==='Ruby asks for a tiny balloon over the bay.'", "Ruby artist direction reaches ordinary editor")
  check("Ruby-written artist direction synchronizes to the ordinary editor", true)
  ab(normal, "fill", "#artist-brief", "JavaScript asks for a ruby-shaped kite.")
  ab(normal, "press", "Tab")
  await waitFor(ruby, `${rubyMaps}.mural.brief==='JavaScript asks for a ruby-shaped kite.' && document.querySelector('#artist-brief').value==='JavaScript asks for a ruby-shaped kite.'`, "ordinary artist direction reaches Ruby editor")
  check("ordinary artist direction synchronizes into the Ruby textarea", true)

  choose(ruby, 11)
  const edgeRect = evaluate(ruby, "(() => { const r=document.querySelector('#mural-canvas').getBoundingClientRect(); return {x:r.x,y:r.y,w:r.width,h:r.height} })()")
  const edgeY = String(Math.round(edgeRect.y + 10.5 * edgeRect.h / 32))
  ab(ruby, "mouse", "move", String(Math.round(edgeRect.x + 57.5 * edgeRect.w / 64)), edgeY)
  ab(ruby, "mouse", "down")
  try { ab(ruby, "mouse", "move", String(Math.round(edgeRect.x + edgeRect.w + 30)), edgeY) }
  finally { ab(ruby, "mouse", "up") }
  await converge()
  check("dragging outside the canvas does not clamp paint onto its edge", maps(ruby).pixels["57,10"] === 11 && [58, 59, 60, 61, 62, 63].every(x => maps(ruby).pixels[`${x},10`] === undefined))

  // Substitute only the OS clipboard boundary; the real share button and
  // application handler execute, and the copied URL must reopen this room.
  evaluate(ruby, "Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>{window.__testSharedURL=value}}})")
  ab(ruby, "click", "#share-mural")
  await waitFor(ruby, "typeof window.__testSharedURL==='string'", "share button copies the room URL")
  const shared = new URL(evaluate(ruby, "window.__testSharedURL"))
  check("share copies a working same-room collaboration link", shared.origin === new URL(BASE).origin && shared.pathname.startsWith(`/docs/${encodeURIComponent(room)}/pixels`))

  choose(ruby, 2)
  stroke(ruby, [18, 6])
  await converge()
  const clientID = status().clientID
  const beforeOffline = { normal: maps(normal).pixels["16,6"], ruby: maps(ruby).pixels["20,6"] }
  ab(ruby, "click", "#wasm-toggle-connection")
  await waitFor(ruby, `${rubyStatus}.offline && !${rubyStatus}.synced`, "explicit Ruby disconnection")
  choose(ruby, 9)
  stroke(ruby, [16, 6])
  stroke(ruby, [18, 6])
  choose(normal, 14)
  stroke(normal, [18, 6])
  stroke(normal, [20, 6])
  const queued = status()
  check("disconnected Ruby continues painting and queues unacknowledged updates", queued.offline && Number.isInteger(queued.pending) && queued.pending > 0)
  check("both clients retain separate views while Ruby is disconnected", maps(normal).pixels["16,6"] === beforeOffline.normal && maps(ruby).pixels["20,6"] === beforeOffline.ruby && maps(ruby).pixels["18,6"] === 9 && maps(normal).pixels["18,6"] === 14)
  await rendered([[16, 6, 9], [18, 6, 9]], "offline Ruby paint is immediately visible")
  ab(ruby, "click", "#wasm-toggle-connection")
  await syncedRuby()
  await waitFor(ruby, `${rubyStatus}.pending===0`, "all queued Ruby updates acknowledged")
  await converge()
  const merged = maps(ruby).pixels
  check("reconnect retains the same Yrs client ID and drains the delivery queue", status().clientID === clientID && status().pending === 0)
  check("offline independent edits survive and the same-pixel conflict converges", merged["16,6"] === 9 && merged["20,6"] === 14 && [9, 14].includes(merged["18,6"]))
  await rendered([[16, 6, 9], [20, 6, 14], [18, 6, merged["18,6"]]], "Ruby renders the merged result")
  check("the Ruby canvas shows the converged conflict winner", true)

  const saved = serializedMaps(ruby)
  ab(ruby, "reload")
  await syncedRuby()
  await converge()
  check("acknowledged painting survives a fresh Ruby runtime and document reload", serializedMaps(ruby) === saved)
  await rendered([[16, 6, 9], [20, 6, 14]], "saved canvas rendered after reload")
  const reloadedStatus = status()
  check("Ruby remembers the painter name across a fresh runtime", evaluate(ruby, "document.querySelector('#your-name').value==='Ruby painter'") && reloadedStatus.peers.some(peer => peer.clientID === reloadedStatus.clientID && peer.user?.name === "Ruby painter"))

  if (LIVE) {
    ab(ruby, "fill", "#artist-brief", "Add a little red ruby gem in the open sky around x=24,y=5, with a few golden sparkles. Preserve every human mark.")
    ab(ruby, "press", "Tab")
    await waitFor(normal, "window.__yrb.mural.get('brief')?.startsWith('Add a little red ruby gem')", "Ruby artist brief reaches normal editor")
    artistInvited = true
    ab(ruby, "click", "#invite-artist-button")
    await waitFor(normal, "[...window.__yrb.provider.awareness.getStates().values()].some(peer=>peer.artist)", "artist invited by Ruby joins normal client", 25_000)
    await waitFor(ruby, `${rubyStatus}.peers.some(p=>p.artist)`, "real artist presence reaches Yrs", 25_000)
    await waitFor(ruby, `${rubyMaps}.mural.turns>=1 || ${rubyMaps}.mural.phase==='error'`, "first actual model turn", 120_000)
    const first = maps(ruby)
    check("the real artist's presence and painted layer reach the Ruby browser", first.mural.turns >= 1 && first.mural.phase !== "error" && Object.keys(first.artist_pixels).length > 0 && status().peers.some(p => p.artist))
    await waitFor(normal, "window.__yrb.mural.get('turns')>=1 && window.__yrb.artistPixels.size>0", "artist invited by Ruby paints in ordinary client")
    check("Ruby invite UI starts a live artist whose note and paint reach the ordinary client", !!first.mural.note && !!maps(normal).mural.note && Object.keys(maps(normal).artist_pixels).length > 0)
    const duplicate = evaluate(normal, "fetch(document.querySelector('#invite-artist').action,{method:'POST',headers:{'X-CSRF-Token':document.querySelector('meta[name=csrf-token]').content}}).then(async response=>{await response.body?.cancel();return response.status})")
    check("a second participant cannot accidentally invite a duplicate artist", duplicate === 409)
    console.log(`artist: ${first.mural.note}`)
    const entry = Object.entries(first.artist_pixels).find(([key, color]) => first.pixels[key] === undefined && color !== 11)
    assert.ok(entry, "artist adds a visible pixel available for human overpainting")
    const [key, artistColor] = entry
    const point = key.split(",").map(Number)
    await rendered([[...point, artistColor]], "Ruby renders the actual artist color")
    check("Ruby draws the artist layer, not just its synchronized metadata", true)
    choose(ruby, 11)
    stroke(ruby, point)
    await painted(normal, { [key]: 11 }, "Ruby human overpaint reaches the main studio")
    await rendered([[...point, 11]], "Ruby human paint covers the artist")
    await waitFor(ruby, `${rubyMaps}.mural.turns>${first.mural.turns} || ${rubyMaps}.mural.phase==='error'`, "artist responds to Ruby browser paint", 120_000)
    const after = maps(ruby)
    check("the live artist reacts to Ruby browser paint without another prompt", after.mural.turns > first.mural.turns && after.mural.phase !== "error")
    check("Ruby human overpaint remains above the artist after its next turn", after.pixels[key] === 11 && maps(normal).pixels[key] === 11)
    await rendered([[...point, 11]], "Ruby still renders human color after the artist responds")
    console.log(`artist after Ruby paint: ${after.mural.note}`)
    ab(normal, "click", "#remove-artist")
    await waitFor(ruby, `!${rubyStatus}.peers.some(p=>p.artist) && ${rubyMaps}.mural.enabled===false`, "artist stops in both clients", 20_000)
    check("the main studio can stop the artist and Ruby observes it leaving", true)
    await converge()

    // Reverse the initiating and stopping roles while the real model is busy.
    ab(normal, "fill", "#artist-brief", "Add a little cream sailboat on the water near x=24,y=27, and leave every human mark intact.")
    ab(normal, "press", "Tab")
    ab(normal, "click", "#invite-artist-button")
    await waitFor(ruby, `${rubyStatus}.peers.some(peer=>peer.artist) && ${rubyMaps}.mural.phase==='thinking'`, "normal studio's new artist begins inference", 35_000)
    ab(ruby, "click", "#remove-artist")
    await waitFor(ruby, `!${rubyStatus}.peers.some(peer=>peer.artist) && ${rubyMaps}.mural.enabled===false`, "Ruby stops artist during inference", 20_000)
    await converge()
    const afterStop = JSON.stringify(canonical(maps(ruby).artist_pixels))
    await sleep(1_500)
    check("Ruby stop UI removes an artist invited by the normal studio during inference", !status().peers.some(peer=>peer.artist) && maps(normal).mural.enabled === false)
    check("an in-flight artist does not paint after the Ruby participant stops it", JSON.stringify(canonical(maps(ruby).artist_pixels)) === afterStop && JSON.stringify(canonical(maps(normal).artist_pixels)) === afterStop)
  }

  // Puma returns a bodyless 204 while its background artist is joining.
  // The real Ruby UI must keep waiting for presence and remain cancelable.
  evaluate(ruby, `(() => {
    window.__testOriginalFetch=window.fetch;
    window.__testInvite204=false;
    window.fetch=(resource,options={}) => {
      const method=String(options.method || resource.method || 'GET').toUpperCase();
      if (method!=='POST') return window.__testOriginalFetch(resource,options);
      window.__testInvite204=true;
      return Promise.resolve(new Response(null,{status:204}));
    };
  })()`)
  try {
    ab(ruby, "click", "#invite-artist-button")
    await waitFor(ruby, "window.__testInvite204", "Ruby invitation receives HTTP 204")
    await sleep(300)
    check("a bodyless HTTP 204 keeps Ruby invited while waiting for artist presence", evaluate(ruby, "document.querySelector('#artist-badge').textContent==='INVITED' && document.querySelector('#invite-artist-button').disabled && !document.querySelector('#remove-artist').hidden && !document.querySelector('#artist-commentary').textContent.includes('left before joining')"))
    ab(ruby, "click", "#remove-artist")
    await waitFor(ruby, "!document.querySelector('#invite-artist-button').disabled && document.querySelector('#remove-artist').hidden", "bodyless invitation cancellation restores controls")
    check("a pending HTTP 204 invitation remains cancelable without a ghost artist", !status().peers.some(peer=>peer.artist))
  } finally {
    evaluate(ruby, "window.fetch=window.__testOriginalFetch")
  }

  // Hold an invitation at the browser network boundary so cancellation has a
  // reproducible pending window and does not start an extra paid model run.
  evaluate(ruby, `(() => {
    window.__testOriginalFetch=window.fetch;
    const inviteURL=document.querySelector('#invite-artist').action;
    window.__testInvitePending=false;
    window.__testInviteAborted=false;
    window.fetch=(resource,options={}) => {
      const method=String(options.method || resource.method || 'GET').toUpperCase();
      if (method!=='POST') return window.__testOriginalFetch(resource,options);
      window.__testInviteURL=new URL(typeof resource==='string' ? resource : resource.url,location.href).href;
      window.__testInvitePending=window.__testInviteURL===inviteURL;
      return new Promise((resolve,reject) => {
        const abort=()=>{window.__testInviteAborted=true;reject(new DOMException('Test invitation canceled','AbortError'))};
        if(options.signal?.aborted) abort(); else options.signal?.addEventListener('abort',abort,{once:true});
      });
    };
  })()`)
  try {
    ab(ruby, "click", "#invite-artist-button")
    await waitFor(ruby, "window.__testInvitePending && !document.querySelector('#remove-artist').disabled", "pending Ruby invitation can be canceled")
    ab(ruby, "click", "#remove-artist")
    await waitFor(ruby, "window.__testInviteAborted && !document.querySelector('#invite-artist-button').disabled", "Ruby invitation request aborts and controls recover")
    check("Ruby can cancel a pending invitation without leaving a ghost artist", !status().peers.some(peer=>peer.artist))
  } finally {
    evaluate(ruby, "window.fetch=window.__testOriginalFetch")
  }

  check("the experiment reports no runtime or synchronization error", !status().error && evaluate(ruby, "document.querySelector('#wasm-error').hidden"))
  check("desktop experiment has no horizontal overflow", evaluate(ruby, "document.documentElement.scrollWidth<=innerWidth"))
  ab(ruby, "screenshot", "--full", join(shots, "pixel-wasm-desktop.png"))
  ab(normal, "screenshot", "--full", join(shots, "pixel-wasm-normal-peer.png"))
  ab(ruby, "set", "viewport", "390", "844")
  await sleep(250)
  check("mobile experiment has no horizontal overflow", evaluate(ruby, "document.documentElement.scrollWidth<=innerWidth"))
  await rendered([[16, 6, 9], [20, 6, 14]], "mobile Ruby canvas still renders the shared marks")
  ab(ruby, "screenshot", "--full", join(shots, "pixel-wasm-mobile.png"))
  for (const session of sessions) {
    const errors = ab(session, "errors")
    if (errors.errors?.length) {
      const path = join(shots, session === ruby ? "pixel-wasm-errors.json" : "pixel-normal-errors.json")
      writeFileSync(path, JSON.stringify(errors.errors, null, 2))
      console.error(`${errors.errors.length} browser errors; first: ${errors.errors[0].text}; complete list: ${path}`)
    }
    check(`${session === ruby ? "Ruby WASM" : "ordinary"} browser has no JavaScript errors`, !errors.errors?.length)
  }
  suitePassed = true
  console.log(`PASS: ${checks} Ruby WASM browser checks (${LIVE ? "live RubyLLM artist" : "no model calls"}); room=${room}`)
} finally {
  if (artistInvited) {
    try {
      evaluate(normal, "window.__yrb?.mural.set('enabled',false)")
      await waitFor(normal, "!window.__yrb || ![...window.__yrb.provider.awareness.getStates().values()].some(p=>p.artist)", "artist cleanup", 20_000)
    } catch (error) { console.warn(`Artist cleanup: ${error.message}`) }
  }
  if (!suitePassed && process.env.KEEP_BROWSER === "1") {
    console.warn(`Browsers retained for diagnosis: normal=${normal}, ruby=${ruby}`)
  } else {
    for (const session of sessions) {
      try { ab(session, "close") } catch { /* Preserve the original test failure. */ }
    }
  }
}
