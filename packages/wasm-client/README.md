# yrby-wasm-client — experimental

An optional browser client built on Yrs WebAssembly, with a Ruby facade for applications running in `ruby.wasm`. The supported, first-class browser path remains [`yrby-client`](../client). This package is a separate experiment, currently local to this repository.

The client owns CRDT state, reliable delivery and presence. Your application owns its interface and behavior. Pixel Bay is one consumer; this package has no pixel maps, canvas selectors, artist prompts or other application-specific state.

## What is available

- Named shared maps, text and arrays through JavaScript handles and Ruby objects.
- Explicit transactions and origin-scoped undo/redo.
- ActionCable-compatible channel subscriptions, Yjs/Yrs synchronization, acknowledgment tracking, retransmission and reconnect replay through the existing `yrby-client` reliable-delivery core.
- Presence, connection status, pending-update counts and deferred change callbacks.
- State vectors, binary updates, pending-update export and restoration for application-managed recovery.
- Consumer ownership rules that allow multiple clients to share an existing application connection.

The Ruby facade is in [`ruby/yrby_wasm.rb`](ruby/yrby_wasm.rb). It runs in browser CRuby and delegates CRDT operations to Yrs WASM through the generic [`src/client.js`](src/client.js). This does not compile the native yrby gem or its Magnus extension into the browser.

## Run the Pixel Bay example

From the repository root, build the normal client's reusable modules, install this package's dependencies, then build the optional example:

```sh
(cd packages/client && npm ci && npm run build)
(cd packages/wasm-client && npm ci)
(cd examples/actioncable-demo/frontend/experiments/ruby-wasm && npm ci && npm run build)
```

The final build uses Bun. Run the [ActionCable demo](../../examples/actioncable-demo) normally, then open `/docs/YOUR_ROOM/pixels/ruby` beside `/docs/YOUR_ROOM/pixels`. Both clients use the same document and existing artist invitation endpoint. The Ruby page loads the same studio interface and binds its behavior in Ruby.

The optional build copies generated assets into `examples/actioncable-demo/public/ruby-wasm/`, which is ignored by Git. The normal page never loads either WASM runtime. The Ruby runtime alone is roughly 29 MB uncompressed; this is a deliberate experiment, not a lightweight default for every visitor.

## Bootstrap a Ruby application

Build the browser version of the pinned Yrs bindings, then initialize them before exposing the Ruby host:

```js
import { DefaultRubyVM } from "@ruby/wasm-wasi/dist/browser"
import { createConsumer } from "@rails/actioncable"
import { createRubyHost } from "yrby-wasm-client/ruby-host"
import initYrs, * as Y from "./vendor/ywasm-browser.js"

await initYrs("/assets/ywasm_bg.wasm")
window.YrbyWasm = createRubyHost({ Y, createConsumer })

const rubyBytes = await fetch("/assets/ruby.wasm").then(r => r.arrayBuffer())
const { vm } = await DefaultRubyVM(await WebAssembly.compile(rubyBytes))
const clientRuby = await fetch("/assets/yrby_wasm.rb").then(r => r.text())
await vm.evalAsync(clientRuby)
await vm.evalAsync(applicationRubySource)
```

The application supplies its own WASM runtime, asset URLs and ActionCable setup. The example bootstrap checks HTTP status and shows startup failures in the page. Load `yrby_wasm.rb` before evaluating application source; there is no browser filesystem `require "yrby"` step.

`createRubyHost` exposes `createClient(optionsJSONString)` for the Ruby facade. Host-level `onError(error, context)` can be supplied for application logging. JSON options cannot replace the initialized Yrs module or override consumer ownership.

## Use shared state from Ruby

```ruby
client = Yrby::Wasm::Client.new(
  channel: "DocumentChannel",
  params: { id: "my-shared-room" },
  presence: { user: { name: "Ruby browser", color: "#c85b50" } }
)

doc = client.doc
settings = doc.map("settings")
text = doc.text("body")
items = doc.array("items")
undo = doc.undo_manager(settings, text, items)

unsubscribe = client.on_change { redraw(settings.to_h, text.to_s, items.to_a) }
client.on_status { |status| show_connection(status["status"], status["pending"]) }
client.connect

# An event handler can update already-opened shared types together.
doc.transaction do
  settings["theme"] = "coral"
  text.insert(text.length, "Hello from Ruby! ")
  items.push({ "label" => "A shared item" })
end
undo.stop_capturing

undo.undo if undo.can_undo?
undo.redo if undo.can_redo?

client.disconnect  # Local editing continues; updates remain queued.
client.connect     # Reuses the document and client ID; exchanges missed edits.
```

Open shared roots before entering a transaction. Transactions batch updates; they do not roll back if the Ruby block raises. Nested transactions are rejected. Avoid asynchronous work inside a transaction.

The default undo manager tracks the local origin and preserves edits from other participants. Use matching `origin:` values on transactions and undo managers when an application needs more than one local author. Call `stop_capturing` between gestures to make each stroke or action one undo step. A shared map's JSON values are atomic values; nested JSON hashes are not automatically separate collaborative maps.

Ruby callbacks are deferred until the active Yrs transaction is released. Callback results are discarded rather than implicitly converting Ruby objects back into JavaScript. `on_change`, `on_status` and undo `on_change` return unsubscribe callables. Call those when disposing a view, and call `client.destroy` when the client is no longer needed.

`client.when_synced` and `client.when_acknowledged` return JavaScript promises. They can be awaited inside an asynchronous Ruby evaluation, not from a synchronous DOM event callback. Inspect `client.synced?`, `client.pending?` or `client.status` for ongoing status.

## Consumer ownership

Use a factory when each client should own its connection:

```js
window.YrbyWasm = createRubyHost({
  Y,
  createConsumer: () => createConsumer("/cable"),
})
```

The host creates one consumer per client and enables connection management for that owned consumer. Disconnecting or destroying a client may close its consumer.

Pass an existing consumer when the application shares it with other subscriptions:

```js
window.YrbyWasm = createRubyHost({ Y, consumer: applicationConsumer })
```

Disconnecting or destroying a client removes only its own subscription and leaves the shared consumer open. Supplying both an existing consumer and a factory uses the existing consumer. The host forces ownership based on which path created the consumer; Ruby options cannot change it.

JavaScript callers can also use `createClient({ Y, consumer, channel, params, localState })` directly from `yrby-wasm-client`. Its `manageConsumer` default is `false`; use `true` only for a consumer owned exclusively by that client.

## Recovery and binary state

`client.pending_update` returns a JavaScript `Uint8Array` containing unacknowledged updates, or Ruby `nil` when there are none. An application can persist these bytes, for example in IndexedDB, and restore them into a new client with `restore_pending_update(bytes)` before reconnecting. Restoration queues the edits for acknowledgment and resend; merely applying an update as remote state does not do that.

`encode_state_vector`, `encode_state_as_update` and `apply_remote_update` support explicit binary synchronization. Keep their values as byte arrays across the Ruby/JavaScript boundary.

The package's live outbox is in memory. It does not silently add IndexedDB persistence or guarantee survival of a tab crash. Page lifecycle hooks handle presence and connection changes, but durable recovery requires application-owned storage of pending updates. Destroying a client clears its in-memory pending state.

## Reusable browser build helper

The npm `ywasm` 0.28.0 package ships a Node loader. The helper retains its generated bindings, converts CommonJS exports to ESM, and replaces filesystem initialization with browser fetching:

```js
import { buildYwasmBrowser } from "yrby-wasm-client/build"

const assets = await buildYwasmBrowser({
  ywasmDir: "./node_modules/ywasm",
  outputFile: "./src/vendor/ywasm-browser.js",
  wasmURL: "/assets/ywasm_bg.wasm",
})
// Bundle the generated module. Copy assets.wasmPath and assets.licensePath
// to the public assets directory; ship the corresponding Ruby license too.
```

This helper uses Node filesystem APIs and is not part of a browser bundle. It deliberately refuses a different ywasm version or an unrecognized loader shape. Review and test the transform when upgrading Yrs rather than editing generated bindings by hand. Ignore generated vendor modules and copied runtime binaries in the consuming application's Git configuration.

## Current boundaries

This package does not replicate `DocumentSessionStore`, document attachment ownership, grant-refresh orchestration, or the Turbo adapter from `yrby-client`. Applications supply channel parameters, own client lifetimes, and can call `renew` when they obtain new credentials; automatic grant renewal and view/session sharing remain application responsibilities.

This is an experimental package with a deliberately small Ruby API. Maps and arrays accept JSON-compatible values; text insertion/deletion uses UTF-16 offsets, matching browser editors and Yjs rather than Ruby character indexes. Applications must respect JavaScript's safe numeric range for JSON numbers.

Yrs and Yjs exchange CRDT updates, but the Yrs object API is not a drop-in `Y.Doc` for Yjs editor bindings. Existing ProseMirror, Tiptap or CodeMirror bindings cannot simply receive this client. XML and richer Yrs operations are available only through the underlying native handles (`client.native[:doc]` in Ruby and shared-type `native` handles), without a Ruby facade or compatibility promise. Using those handles also makes their lifetime and transaction rules the caller's responsibility.

CRDT convergence preserves concurrent operations; it does not establish application permissions, human-over-agent priority, valid layouts or semantic correctness. Pixel Bay implements its own layer policy above this client. Use the ordinary `yrby-client` path for the existing supported editor integrations.
