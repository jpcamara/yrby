// Shared page plumbing for every demo: the provider, the room bar, presence, and
// the status line. The per-demo files hold only the Yjs binding.
//
// The consumer comes from @anycable/web rather than @rails/actioncable because
// the server is AnyCable: anycable-go, embedded in the thrust proxy, terminates
// every socket. Its subscription exposes `whisper`, and yrby-client's provider
// routes awareness through it when it is there — so cursor and presence traffic
// is relayed client-to-client by Go and never reaches Ruby at all. Document
// updates still go through the server, get recorded, and get acked. The two
// consumers are otherwise interchangeable; the provider takes either.
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
// yrby-client whispers awareness frames when the subscription offers
// `whisper` and sends everything else. A whisper is relayed by anycable-go
// between clients and never becomes an RPC call, so `whispers` climbing while
// carets move is the visible proof that presence traffic is not costing Ruby
// anything. Document updates stay on `send`: they have to be recorded and
// acked.
function countTransport(subscription) {
  const counts = { whispers: 0, sends: 0, canWhisper: typeof subscription.whisper === "function" }
  window.__yrbyTransport = counts

  const whisper = subscription.whisper?.bind(subscription)
  if (whisper) {
    subscription.whisper = (payload) => {
      counts.whispers++
      return whisper(payload)
    }
  }
  const send = subscription.send.bind(subscription)
  subscription.send = (payload) => {
    counts.sends++
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
export function renderPresence(provider) {
  const el = presenceEl()
  if (!el) return
  el.replaceChildren(
    ...[...provider.awareness.getStates().values()]
      .map((state) => state.user)
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
// document key comes from the mount element's data attribute, which the server
// rendered from the URL.
export function connectRoom(ydoc, mount) {
  const documentKey = mount.dataset.documentKey
  const consumer = noticeAwareConsumer(createConsumer(cableUrl()), {
    onNotice: () =>
      showNotice(
        "This room has reached its document size cap and is no longer accepting edits. " +
        "Open a new room to keep going.",
      ),
    onRejected: () =>
      showNotice("Could not join this room. It may be full, or the site may be at capacity."),
  })

  const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentKey })
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
