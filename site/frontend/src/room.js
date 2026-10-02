// Shared page plumbing for every demo: the provider, the room bar, presence, and
// the status line. The per-demo files hold only the Yjs binding.
//
// The consumer comes from @anycable/web rather than @rails/actioncable because
// the server is AnyCable: anycable-go, embedded in the thrust proxy, terminates
// every socket. AnyCable subscriptions expose `whisper` (a client-to-client
// relay that never reaches Ruby), and yrby-client's provider rides it for
// awareness when it is there. This demo deliberately hides `whisper` from the
// provider (see countTransport): the rooms are public and anonymous, so a
// whisper would be an unguarded path a raw peer could inject document frames
// through. Awareness rides `send` instead — the same guarded path document
// updates take — so every frame passes the server's throttle and validation.
// The two consumers are otherwise interchangeable; the provider takes either.
import { createConsumer } from "@anycable/web"
import { ActionCableProvider } from "yrby-client"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]

export const user = { name: pick(NAMES), color: pick(COLORS) }

// crypto.randomUUID exists only in secure contexts (https, localhost). The
// demos also run over plain http on a LAN — a Raspberry Pi, a staging box —
// where calling it throws and takes the whole page module down with it.
// getRandomValues is available everywhere; this builds a v4 UUID from it.
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

// The server sends `{ notice: ... }` when a room stops accepting writes (it has
// hit the per-document byte cap) — see site/app/channels/document_channel.rb.
// yrby-client's provider ignores envelopes it doesn't recognize, so this wraps
// the consumer and reads them off the wire before the provider's own handler.
// The subscription mixin the provider builds closes over the provider rather
// than over `this`, so spreading it is safe.
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

// Which path each frame took, exposed for the browser console and the e2e.
//
// The demo hides `whisper` from the provider (below), so both awareness and
// document frames leave over `send` — the guarded server path. That is the
// point of this counter now: `awarenessSends` climbing while carets move proves
// presence rides the same guarded path as edits, not an unguarded client-to-
// client relay. Awareness frames are told apart by their first byte
// (MessageType.Awareness === 1 in the y-protocols framing yrby-client speaks).
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

  // Do not offer whisper to the provider: with it absent, yrby-client falls back
  // to `send` for awareness, so presence goes through guarded_receive like every
  // other frame. AnyCable's own whisper still exists on the raw subscription; the
  // demo simply declines to use it. See the security note at the top of the file.
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

// action_cable_meta_tag renders a same-origin path ("/cable"); the AnyCable
// client wants an absolute ws:// or wss:// URL, so resolve it here rather than
// depending on either end's relative-URL handling.
function cableUrl() {
  const meta = document.querySelector("meta[name=action-cable-url]")
  const path = meta?.getAttribute("content") || "/cable"
  if (/^wss?:/.test(path)) return path
  return new URL(path, location.href).href.replace(/^http/, "ws")
}

// Copy link / open a second window. The whole point of the site is seeing two
// clients converge, so the affordance is a button rather than an instruction.
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
      url.select() // clipboard permission denied; leave it selected to copy by hand
      copy.textContent = "Press ⌘C"
    }
    setTimeout(() => { copy.textContent = "Copy link" }, 2000)
  })

  second?.addEventListener("click", () => {
    window.open(url.value, "_blank", "width=900,height=800,noopener")
  })
}

// The site accepts no uploads. Nothing here has an upload endpoint and the app
// does not install Active Storage, but a browser will still happily turn a
// pasted or dropped file into content if an editor asks for it — so files are
// refused at the page level too, before any editor sees the event. Text pastes
// are untouched.
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
    document.addEventListener(type, stop, true) // capture: ahead of any editor handler
  }
}

// Everyone in the room, as colored chips. Awareness is relayed by the server and
// stored nowhere, so this list is only ever as fresh as the live connections.
// Two state shapes appear: the demos set { user: { name, color } }, and
// Lexical-family bindings (lexxy-realtime's cursors) publish { name, color }
// at the top level — replacing whatever was there, so both are read.
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

// Builds the provider for this page's room and wires the shared chrome. The
// client never names its document: it presents the signed token the server
// rendered into the mount element, and the channel derives the key from that —
// the same access model on every demo. Channel and params default to the shape
// demos' DocumentChannel; the Lexxy page overrides both to reach NoteChannel
// with its field-scoped token.
export function connectRoom(ydoc, mount, { channel = "DocumentChannel", params } = {}) {
  const consumer = noticeAwareConsumer(createConsumer(cableUrl()), {
    onNotice: () =>
      showNotice(
        "This room has reached its document size cap and is no longer accepting edits. " +
        "Open a new room to keep going.",
      ),
    onRejected: () =>
      showNotice("Could not join this room. It may be full, or the site may be at capacity."),
  })

  const provider = new ActionCableProvider(ydoc, consumer, channel, params || { token: mount.dataset.token })
  provider.awareness.setLocalStateField("user", user)
  provider.awareness.on("update", () => renderPresence(provider))

  const status = statusEl()
  status.dataset.state = "connecting"
  status.textContent = `connecting as ${user.name}…`
  provider.onStatusChange(({ status: state }) => {
    status.dataset.state = state === "synced" ? "connected" : state
    status.textContent = state === "synced" ? `synced, editing as ${user.name}` : `${state}…`
    // disconnect() clears this client's awareness entry, and setLocalStateField
    // is a no-op while the local state is null — so an explicit reconnect has to
    // republish the identity or this browser stays invisible to its peers.
    if (state !== "disconnected" && !provider.awareness.getLocalState()) {
      provider.awareness.setLocalState({ user })
    }
  })

  setupRoomBar()
  refuseFiles()
  renderPresence(provider)
  return provider
}

// The "server-side read" panel every demo carries: a GET-only endpoint that
// reconstructs the document in Ruby (read_text/read_xml/read_map/read_array, or
// the Rich text demo's materialized note.body). It fetches when the panel opens
// and stays live while open — each edit schedules a debounced re-fetch, so the
// panel tracks what the server reads back as you type. The debounce waits for
// the server to record the change and keeps continuous typing from hammering
// the endpoint. No-op if the page has no panel.
export function wireStoredPanel(ydoc) {
  const stored = document.querySelector("#stored-html")
  const details = document.querySelector("details.stored")
  if (!stored || !details) return

  // Indent markup for display. Block tags get their own line at their depth;
  // text and inline tags stay on the line with their content, so a paragraph
  // reads as one line while lists and tables nest. <pre> content is passed
  // through untouched. Display-only — the endpoint returns the stored string.
  // (Tokenizer limitation: a ">" inside a quoted attribute would split a tag;
  // none of the demo renderers emit one.)
  // The second alternation covers read_xml's ProseMirror mark names, which
  // serialize as tags (<bold>, <italic>) but belong on the line with their text.
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
        if (last === "close") newline() // had block children: close on its own line
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

  // read_map/read_array return compact JSON, the lexxy demo returns HTML, and
  // read_xml returns tag-per-block markup; re-indent whichever this is for the
  // panel. Plain text (read_text) displays as-is.
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
      stored.firstChild.textContent = body ? pretty(body) : "(empty — edit the document first)"
    } catch {
      stored.firstChild.textContent = "(could not load)"
    }
  }

  let timer = null
  ydoc.on("update", () => {
    if (!details.open) return
    clearTimeout(timer)
    timer = setTimeout(load, 600)
  })
  details.addEventListener("toggle", () => { if (details.open) load() })
}
