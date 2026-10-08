// Page setup shared by every demo: the provider, the room bar, presence, and
// the status line. Each demo's own file only sets up its Yjs binding.
//
// The consumer comes from @anycable/web because the server is AnyCable.
// anycable-go, embedded in the thrust proxy, handles every socket. The
// provider also works with @rails/actioncable.
//
// AnyCable subscriptions have `whisper`, which sends a message straight to
// other clients without going through Ruby. yrby-client's provider uses it for
// awareness when it's there. This demo hides `whisper` from the provider (see
// countTransport). The rooms are public and anonymous, so a raw client could
// use a whisper to send document frames to its peers with no checks. Without
// it, awareness goes over `send` like document updates do, and the server
// throttles and validates every frame.
import { createConsumer } from "@anycable/web"
import { ActionCableProvider } from "yrby-client"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]

export const user = { name: pick(NAMES), color: pick(COLORS) }

// crypto.randomUUID only exists in secure contexts (https and localhost). The
// demos also run over plain http on a LAN, like on a Raspberry Pi or a staging
// box. There, calling it throws and breaks the whole page module.
// getRandomValues works everywhere, so this builds a v4 UUID from it.
export function uid() {
  if (crypto.randomUUID) return crypto.randomUUID()
  const b = crypto.getRandomValues(new Uint8Array(16))
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("")
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

const statusEl = () => document.getElementById("status")
const noticeEl = () => document.getElementById("notice")
const presenceEl = () => document.getElementById("presence")

function showNotice(text) {
  const el = noticeEl()
  if (!el) return
  el.textContent = text
  el.hidden = false
}

// The server sends `{ notice: ... }` when a room hits the per-document byte cap
// and stops accepting writes (see app/channels/concerns/room_guarded.rb).
// yrby-client's provider ignores messages it doesn't recognize, so this wraps
// the consumer and reads notices before the provider's handler sees them. The
// provider's subscription mixin refers to the provider directly, not `this`,
// so spreading it is safe.
function noticeAwareConsumer(consumer, { onNotice, onRejected }) {
  return {
    subscriptions: {
      create(channel, mixin) {
        const subscription = consumer.subscriptions.create(channel, {
          ...mixin,
          received(message) {
            if (message && message.notice) {
              onNotice(message)
              return
            }
            return mixin.received.call(this, message)
          },
          rejected() {
            onRejected()
            if (mixin.rejected) mixin.rejected.call(this)
          },
        })
        return countTransport(subscription)
      },
    },
  }
}

// Counts which path each frame took, for the browser console and the e2e
// tests.
//
// The demo hides `whisper` from the provider (below), so awareness and
// document frames both go out over `send` and through the server's checks.
// When carets move and `awarenessSends` goes up, that shows presence uses the
// same checked path as edits. Awareness frames are recognized by their first
// byte (MessageType.Awareness === 1 in the y-protocols framing yrby-client
// uses).
function isAwarenessPayload(payload) {
  const update = payload && payload.update
  if (typeof update !== "string") return false
  try {
    return atob(update).charCodeAt(0) === 1
  } catch {
    return false
  }
}

function countTransport(subscription) {
  const counts = { sends: 0, awarenessSends: 0, documentSends: 0, canWhisper: false }
  window.__yrbyTransport = counts

  // Hide whisper from the provider. Without it, yrby-client sends awareness
  // with `send`, so presence goes through guarded_receive like every other
  // frame. The raw AnyCable subscription still has whisper. The demo just
  // doesn't use it. See the note at the top of this file.
  subscription.whisper = undefined

  const send = subscription.send.bind(subscription)
  subscription.send = (payload) => {
    counts.sends++
    if (isAwarenessPayload(payload)) counts.awarenessSends++
    else counts.documentSends++
    return send(payload)
  }
  return subscription
}

// action_cable_meta_tag renders a same-origin path ("/cable"). The AnyCable
// client wants an absolute ws:// or wss:// URL, so build one here without
// relying on how either side handles relative URLs.
function cableUrl() {
  const meta = document.querySelector("meta[name=action-cable-url]")
  const path = meta?.getAttribute("content") || "/cable"
  if (/^wss?:/.test(path)) return path
  return new URL(path, location.href).href.replace(/^http/, "ws")
}

// The copy link and second window buttons. The site is about watching two
// clients stay in sync, so opening a second one should take one click.
function setupRoomBar() {
  const url = document.getElementById("room-url")
  const copy = document.getElementById("copy-room")
  const second = document.getElementById("second-window")
  if (!url) return

  copy?.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(url.value)
      copy.textContent = "Copied"
    } catch {
      url.select() // no clipboard permission, so select it for copying by hand
      copy.textContent = "Copy the selected link"
    }
    setTimeout(() => { copy.textContent = "Copy link" }, 2000)
  })

  second?.addEventListener("click", () => {
    window.open(url.value, "_blank", "width=900,height=800,noopener")
  })
}

// The site doesn't accept uploads. There's no upload endpoint and the app
// doesn't install Active Storage. A browser will still turn a pasted or
// dropped file into content if an editor asks for it, so the page blocks files
// before any editor sees the event. Text pastes work normally.
const carriesFiles = (transfer) =>
  !!transfer && (Array.from(transfer.types || []).includes("Files") || (transfer.files || []).length > 0)

function refuseFiles() {
  const stop = (event) => {
    const transfer = event.clipboardData || event.dataTransfer
    if (!carriesFiles(transfer)) return
    event.preventDefault()
    event.stopPropagation()
  }
  for (const type of ["paste", "drop", "dragover"]) {
    document.addEventListener(type, stop, true) // capture, so this runs before editor handlers
  }
}

// Everyone in the room, as colored chips. The server relays awareness and
// doesn't store it, so this list only shows live connections. There are two
// state shapes. The demos set { user: { name, color } }. Lexical bindings
// (lexxy-realtime's cursors) set { name, color } at the top level and replace
// whatever was there. This reads both.
export function renderPresence(provider) {
  const el = presenceEl()
  if (!el) return
  el.replaceChildren(
    ...[...provider.awareness.getStates().values()]
      .map((state) => state.user || (state.name ? { name: state.name, color: state.color } : null))
      .filter(Boolean)
      .map((u) => {
        const chip = document.createElement("span")
        chip.className = "chip"
        chip.style.background = u.color
        chip.textContent = u.name === user.name ? `${u.name} (you)` : u.name
        return chip
      }),
  )
}

// The cable consumer every demo uses: @anycable/web, wrapped so the page reads
// the server's notices and the provider never sees `whisper`. The Lexxy page
// hands it to <yrby-document>, and the other demos pass it to their provider.
export function roomConsumer() {
  return noticeAwareConsumer(createConsumer(cableUrl()), {
    onNotice: () =>
      showNotice(
        "This room has reached its size limit, so new edits won't be saved or shared. " +
        "Open the demo again to start a new room.",
      ),
    onRejected: () =>
      showNotice("Couldn't join this room. It may be full, or the site may be busy. Try again in a minute, or open the demo again for a new room."),
  })
}

// The room bar and the file blocker. Every demo page has both.
export function setupRoomPage() {
  setupRoomBar()
  refuseFiles()
}

// Shows the provider's connection state in the status line and everyone in
// the room as chips. Returns a function that stops both.
export function showRoomState(provider) {
  const status = statusEl()
  const STATUS_TEXT = { connecting: "Connecting…", connected: "Syncing…", disconnected: "Disconnected" }
  const render = ({ status: state }) => {
    status.dataset.state = state === "synced" ? "connected" : state
    status.textContent = state === "synced" ? `Synced. You're editing as ${user.name}.` : (STATUS_TEXT[state] ?? state)
  }
  const onPresence = () => renderPresence(provider)
  const offStatus = provider.onStatusChange(render)
  provider.awareness.on("update", onPresence)
  render({ status: provider.status })
  renderPresence(provider)
  return () => {
    offStatus()
    provider.awareness.off("update", onPresence)
  }
}

// Builds the provider for a shape demo's room and sets up the shared page
// parts. The client never names its document. It sends the signed token the
// server rendered into the mount element, and DocumentChannel gets the key
// from that.
export function connectRoom(ydoc, mount) {
  const provider = new ActionCableProvider(ydoc, roomConsumer(), "DocumentChannel", { token: mount.dataset.token })
  provider.awareness.setLocalStateField("user", user)
  provider.onStatusChange(({ status: state }) => {
    // disconnect() clears this client's awareness entry, and
    // setLocalStateField does nothing while the local state is null. After a
    // reconnect, set the identity again or other people won't see this browser.
    if (state !== "disconnected" && !provider.awareness.getLocalState()) {
      provider.awareness.setLocalState({ user })
    }
  })

  showRoomState(provider)
  setupRoomPage()
  return provider
}

// The "server-side read" panel on every demo. It calls a GET endpoint that
// rebuilds the document in Ruby with read_text, read_xml, read_map, or
// read_array, or returns note.body for the Lexxy demo. It fetches when
// the panel opens and again after edits while it's open, so it shows what the
// server reads back as you type. The fetch is debounced, which gives the
// server time to record the change and avoids a request per keystroke. Does
// nothing if the page has no panel. Returns a function that stops listening,
// for a page whose Yjs document can be replaced.
export function wireStoredPanel(ydoc) {
  const stored = document.querySelector("#stored-html")
  const details = document.querySelector("details.stored")
  if (!stored || !details) return () => {}

  // Indents markup for display. Block tags go on their own line at their
  // depth. Text and inline tags stay on the line with their content, so a
  // paragraph is one line and lists and tables nest. Content inside <pre> is
  // left alone. This is only for display. The endpoint returns the stored
  // string. A ">" inside a quoted attribute would split a tag, but none of
  // the demo renderers output one.
  // The extra names at the end of INLINE are read_xml's ProseMirror marks.
  // They come out as tags (<bold>, <italic>) but belong on the line with
  // their text.
  const INLINE = /^(a|abbr|b|bdi|bdo|br|cite|code|data|del|dfn|em|i|ins|kbd|mark|q|s|samp|small|span|strong|sub|sup|time|u|var|wbr|bold|italic|strike|underline|link|highlight)$/
  const VOID = /^(area|base|br|col|embed|hr|img|input|link|meta|source|track|wbr)$/
  const prettyMarkup = (html) => {
    const tokens = html.match(/<[^>]+>|[^<]+/g) || []
    let out = ""
    let depth = 0
    let inPre = false
    let last = "start"
    const newline = () => {
      if (out) out += "\n"
      out += "  ".repeat(depth)
    }
    for (const token of tokens) {
      const tag = (token.startsWith("<") && token.match(/^<\/?([a-zA-Z][\w-]*)/)?.[1].toLowerCase()) || null
      if (inPre) {
        out += token
        if (tag === "pre" && token.startsWith("</")) { inPre = false; last = "close" }
        continue
      }
      if (tag === null) { // text
        if (token.trim()) { out += token; last = "text" }
        continue
      }
      if (INLINE.test(tag)) { out += token; last = "text"; continue }
      if (token.startsWith("</")) {
        depth = Math.max(0, depth - 1)
        if (last === "close") newline() // it had block children, so close on its own line
        out += token
        last = "close"
      } else if (VOID.test(tag) || token.endsWith("/>")) {
        newline()
        out += token
        last = "close"
      } else {
        newline()
        out += token
        if (tag === "pre") { inPre = true } else { depth++ }
        last = "open"
      }
    }
    return out
  }

  // read_map and read_array return compact JSON, the Lexxy demo returns HTML,
  // and read_xml returns one tag per block. Indent whichever it is. Plain text
  // from read_text is shown as is.
  const pretty = (body) => {
    try {
      return JSON.stringify(JSON.parse(body), null, 2)
    } catch {
      return body.trimStart().startsWith("<") ? prettyMarkup(body) : body
    }
  }

  const load = async () => {
    try {
      const response = await fetch(stored.dataset.url, { headers: { Accept: "application/json" } })
      const { body } = await response.json()
      stored.firstChild.textContent = body ? pretty(body) : "Nothing stored yet. Edit the document and this panel will update."
    } catch {
      stored.firstChild.textContent = "Couldn't load the stored document."
    }
  }

  let timer = null
  const onUpdate = () => {
    if (!details.open) return
    clearTimeout(timer)
    timer = setTimeout(load, 600)
  }
  const onToggle = () => { if (details.open) load() }
  ydoc.on("update", onUpdate)
  details.addEventListener("toggle", onToggle)
  return () => {
    clearTimeout(timer)
    ydoc.off("update", onUpdate)
    details.removeEventListener("toggle", onToggle)
  }
}
