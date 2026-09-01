# AnyCable and multi-process

Most Rails apps run several processes, and any of them might serve a given
document. Two pieces keep them in step.

## Broadcasts have to cross processes

The Action Cable adapter is what carries a broadcast from the process that
received a change to the processes holding the other clients. It needs to be
something like `redis` or `solid_cable`, not `async`. The `async` adapter is
in-process; with more than one process it silently splits your room in half.

## Every process rebuilds from the store

Document state is never authoritative in Action Cable process memory. Every
process rebuilds it from the durable store through `on_load`. Because changes
are recorded before broadcast, record-before-distribute holds across processes:
whichever process receives a change records it to the shared store before
anyone, anywhere, sees it.

Those two together are the whole multi-process story. There is no sticky
routing, no per-document ownership, and no coordination between processes.

`bun multiprocess.mjs` in the demo runs clients across two processes and checks
convergence, fresh reads on both, presence across processes, and one shared log.

## AnyCable

yrby fully supports AnyCable. The demo checks this against a real anycable-go
plus RPC server (`frontend/anycable_probe.mjs`, `anycable_concurrent.mjs`):
liveness, the yrby client provider, cross-process reads, and concurrent
convergence.

This site runs on it too, in the smallest arrangement AnyCable has:
[anycable-thruster](https://github.com/anycable/thruster) embeds anycable-go in
the Thruster proxy, so `thrust bin/rails server` is the whole deployment. The Go
server owns `/cable` and calls Rails back over HTTP RPC at a path AnyCable
mounts in the app; Rails hands broadcasts back over localhost. No Redis and no
separate RPC process, because there is one node. The
[site README](https://github.com/jpcamara/yrby/blob/main/site/README.md) has the
configuration.

Two things differ from Action Cable, and both come from AnyCable's execution
model rather than from yrby.

**The channel instance does not survive between messages.** Each RPC command
gets a fresh channel object, so an instance variable set in `subscribed` is gone
by the time `receive` runs. Pass the key on every action:

```ruby
def subscribed    = sync_subscribed(params[:id])
def receive(data) = sync_receive(data, params[:id])
```

That is why the generated channel is written this way even though a plain Action
Cable app could get away with an ivar.

**Connection-scoped state has to be declared.** If you are keeping an ephemeral
document on the connection rather than in a database, declare it as channel
state with `state_attr_accessor` (from anycable-rails) and Base64 it, because
that state is serialized as JSON into each RPC exchange with `anycable-go`:

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

  def authorized?(_key) = true # per-connection scratchpad — every subscriber gets their own
end
```

Keep the payload in mind: the blob travels with every message, so that variant
suits small documents, not long manuscripts.

## Awareness whispers

Under AnyCable the channel subscribes a second stream for awareness with
`whisper: true`. That scopes the client-to-client path to ephemeral presence and
keeps the durable document stream server-mediated: document updates are still
recorded and acked by the server, and only presence takes the short path.

On plain Action Cable there is no whisper mechanism and both travel the same
way. Nothing in your channel changes; the concern checks whether the transport
offers it.

The browser half has to opt in too, by using an AnyCable consumer.
`yrby-client`'s provider whispers awareness when `subscription.whisper` exists,
which `@anycable/web` provides and `@rails/actioncable` does not. The two are
otherwise interchangeable — the provider takes either — so this is a one-import
change:

```js
import { createConsumer } from "@anycable/web"
```

What it buys is that cursor and selection traffic, the part that scales with
pointer movement, is relayed between clients by the Go server and never becomes
an RPC call. Document updates still go through the server, because they have to
be recorded and acked.

## Threads and the GVL

A `Doc` is safe to share across Ruby threads — Puma workers, Action Cable
connection threads, background jobs — with no external locking.
`test/thread_safety_test.rb` runs shared docs, the full sync handshake, and
fan-in sync across 8 threads at once, and checks the interleaving doesn't change
convergence.

Every method that does real CRDT work releases the Global VM Lock while the
native code runs, so CRDT work parallelizes across Ruby threads on MRI, not just
JRuby and TruffleRuby. `bench/parallelism_bench.rb` measures over 2x wall-clock
speedup applying a ~900 KB update concurrently. A thread applying a large update
holds the doc's write lock without holding the GVL, so other Ruby threads keep
running instead of queuing behind it.

Each method has the same shape: copy Ruby byte strings first, drop the GVL, do
the yrs work while taking and releasing native locks entirely inside the
closure, take the GVL back, then build Ruby objects. No Ruby API is touched
without the GVL, and no native lock is held while reacquiring it, so the lock
order can't deadlock. Panics in native code are caught and re-raised as Ruby
exceptions.
