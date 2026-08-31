// Shared page plumbing for every demo: the provider, the room bar, presence, and
// the status line. The per-demo files hold only the Yjs binding.
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]

export const user = { name: pick(NAMES), color: pick(COLORS) }

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
        return consumer.subscriptions.create(channel, {
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
      },
    },
  }
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
  const consumer = noticeAwareConsumer(createConsumer(), {
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
