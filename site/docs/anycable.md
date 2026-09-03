# AnyCable and multi-process

Most Rails apps run several processes, and any of them might end up serving a
given document. Two things keep them consistent.

## Broadcasts have to cross processes

The Action Cable adapter carries a broadcast from the process that received a
change to the processes holding the other clients. Use `redis`, `solid_cable`,
or another adapter that crosses processes. The `async` adapter only works inside
one process. Run it with two processes and your room silently splits in half.

## Every process rebuilds from the store

Action Cable process memory is never the source of truth for a document. Every
process rebuilds the document from the durable store through `on_load`. Changes
are recorded before they're broadcast, and that holds across processes too:
whichever process receives a change writes it to the shared store before any
client in any process sees it.

There's nothing else to set up. There is no sticky routing, no per-document
ownership, and no coordination between processes.

`bun multiprocess.mjs` in the demo runs clients across two processes. It checks
that the documents converge, that fresh reads work on both processes, that
presence crosses processes, and that both processes write to one shared log.

## AnyCable

yrby supports AnyCable end to end. The demo checks it against a real anycable-go
server and RPC server, in `frontend/anycable_probe.mjs` and
`anycable_concurrent.mjs`. Those cover liveness, the yrby client provider,
cross-process reads, and convergence under concurrent editing.

This site runs on AnyCable too, in the smallest setup AnyCable offers.
[anycable-thruster](https://github.com/anycable/thruster) embeds anycable-go in
the Thruster proxy, so `thrust bin/rails server` is the entire deployment. The
Go server owns `/cable`. It calls Rails back over HTTP RPC at a path AnyCable
mounts in the app, and Rails hands broadcasts back to it over localhost. There's
no Redis and no separate RPC process, because it's a single node. The
[site README](https://github.com/jpcamara/yrby/blob/main/site/README.md) has the
configuration.

Two things work differently from plain Action Cable. Both come from how AnyCable
executes channels, and neither is specific to yrby.

**The channel instance does not survive between messages.** Each RPC command
gets a fresh channel object. An instance variable you set in `subscribed` is
gone by the time `receive` runs. So pass the key on every action:

```ruby
def subscribed    = sync_subscribed(params[:id])
def receive(data) = sync_receive(data, params[:id])
```

That's why every channel example in these docs is written this way, and why the
gem's own `Y::DocumentChannel` re-derives its document from the grant on every
command. A plain Action Cable app could get away with an instance variable, but
the examples don't rely on it.

**Connection-scoped state has to be declared.** If you keep an ephemeral
document on the connection instead of in a database, declare it as channel
state with `state_attr_accessor` from anycable-rails, and Base64 the bytes. That
state is serialized as JSON into every RPC exchange with `anycable-go`:

```ruby
class ScratchpadChannel < ApplicationCable::Channel
  include Y::ActionCable

  state_attr_accessor :doc_state

  on_load { |key| doc_state && Base64.strict_decode64(doc_state) }

  on_change do |key, update|
    doc = Y::Doc.new
    doc.apply_update(Base64.strict_decode64(doc_state)) if doc_state
    doc.apply_update(update)
    self.doc_state = Base64.strict_encode64(doc.compacted_state_update)
  end

  def subscribed    = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])

  private

  def authorized?(_key) = true # per-connection scratchpad: every subscriber gets their own
end
```

Keep the payload size in mind. The blob travels with every message, so this
only makes sense for small documents.

## Awareness whispers

Under AnyCable the channel subscribes a second stream for awareness with
`whisper: true`. Whispers go from client to client, and only presence uses them.
Document updates keep going through the server, where they are recorded and
acked.

Plain Action Cable has no whisper mechanism, so there presence and document
updates travel the same way. Your channel code is the same either way. The
concern checks whether the transport offers whispers.

The browser has to opt in as well, by using an AnyCable consumer. The
`yrby-client` provider whispers awareness when `subscription.whisper` exists.
`@anycable/web` provides it and `@rails/actioncable` does not. The provider
accepts either consumer, so switching is a one-import change:

```js
import { createConsumer } from "@anycable/web"
```
What you get is that cursor and selection traffic, which scales with pointer
movement, is relayed between clients by the Go server and never turns into an
RPC call. Document updates still go through the server, because they have to be
recorded and acked.

## Threads and the GVL

A `Doc` is safe to share across Ruby threads (Puma workers, Action Cable
connection threads, background jobs) with no locking on your side.
`test/thread_safety_test.rb` runs shared docs, the full sync handshake, and
fan-in sync across 8 threads at once, and checks that the interleaving doesn't
change convergence.

Every method that does real CRDT work releases the Global VM Lock while the
native code runs. So CRDT work runs in parallel across Ruby threads on MRI, and
you don't need JRuby or TruffleRuby for that. `bench/parallelism_bench.rb`
measures over 2x wall-clock speedup applying a roughly 900 KB update
concurrently. A thread applying a large update holds the doc's write lock
without holding the GVL, so the other Ruby threads keep running.

Each of those methods follows the same steps. Copy the Ruby byte strings first.
Release the GVL. Do the yrs work, taking and releasing the native locks inside
that closure. Take the GVL back. Then build the Ruby objects. No Ruby API is
touched without the GVL, and no native lock is held while reacquiring it, so
the lock order can't deadlock. A panic in native code is caught and re-raised
as a Ruby exception.
