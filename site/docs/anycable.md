# AnyCable and multi-process

Most Rails apps run several processes, and any of them might handle messages
for a given document. Two things keep them consistent.

## Broadcasts have to cross processes

The Action Cable adapter sends a broadcast from the process that received a
change to the processes serving the other clients. Use `redis`, `solid_cable`,
or another adapter that works across processes. The `async` adapter only works
inside one process. If you run two processes with it, clients on one process
never see edits made on the other.

## Every process rebuilds from the store

yrby doesn't keep documents in process memory between messages. Every process
loads the document from your store through `on_load`. Whichever process
receives a change writes it to the store before any client sees it.

You don't need sticky routing, per-document ownership, or any coordination
between processes.

In the demo app, `bun multiprocess.mjs` runs clients across two processes. It
checks that the documents converge, that fresh reads work on both processes,
that presence reaches clients on the other process, and that both processes
write to one shared log.

## AnyCable

yrby supports AnyCable end to end. The demo app tests it against a real
anycable-go server and RPC server in `frontend/anycable_probe.mjs` and
`frontend/anycable_concurrent.mjs`. Those scripts check liveness, reads from a
different process, and convergence under concurrent editing.

This site runs on AnyCable in its smallest setup.
[anycable-thruster](https://github.com/anycable/thruster) embeds anycable-go in
the Thruster proxy, so `thrust bin/serve` is the whole deployment. The Go
server handles `/cable` and calls Rails over HTTP RPC at a path that AnyCable
mounts in the app. Rails sends broadcasts back to it over localhost. A single
node needs no Redis and no separate RPC process. The
[site README](https://github.com/jpcamara/yrby/blob/main/site/README.md) has the
configuration.

AnyCable runs channels differently from Action Cable in two ways that matter
here. Neither is specific to yrby.

### The channel instance doesn't survive between messages

AnyCable builds a new channel object for each RPC command. An instance variable
you set in `subscribed` is gone by the time `receive` runs, so pass the key on
every action:

```ruby
def subscribed    = sync_subscribed(params[:id])
def receive(data) = sync_receive(data, params[:id])
```

Every channel example in these docs passes the key to `sync_receive` for this
reason. The gem's `Y::DocumentChannel` declares its authorized document key as
channel state when anycable-rails is loaded, and looks the record up again from
the grant when it needs it. On plain Action Cable an instance variable would
work, but the examples are written to run on both.

### Connection-scoped state has to be declared

If you keep an ephemeral document on the connection and not in a database,
declare it as channel state with `state_attr_accessor` from anycable-rails.
Base64-encode the bytes, because that state is serialized as JSON into every
RPC exchange with `anycable-go`:

```ruby
class ScratchpadChannel < ApplicationCable::Channel
  include Y::ActionCable

  state_attr_accessor :doc_state

  on_load { |key| doc_state && Base64.strict_decode64(doc_state) }

  on_change do |key, update|
    doc = Y::Doc.new
    doc.apply_update(Base64.strict_decode64(doc_state)) if doc_state
    doc.apply_update(update)
    self.doc_state = Base64.strict_encode64(doc.encode_state_as_update)
  end

  def subscribed    = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])

  private

  def authorized?(_key) = true # each subscriber gets its own scratchpad on this connection
end
```

The state goes back and forth with every message, so this only makes sense for
small documents.

## Awareness whispers

Under AnyCable the channel subscribes to a second stream for awareness with
`whisper: true`. A whisper goes from one client to the others through
anycable-go, and only presence uses it. Document updates still go through the
server, where they're recorded and acked.

Plain Action Cable has no whispers, so presence and document updates both go
through the server. Your channel code is the same on both. The concern checks
whether the transport supports whispers.

The browser opts in by using an AnyCable consumer. The `yrby-client` provider
whispers awareness when `subscription.whisper` exists. `@anycable/web` provides
it and `@rails/actioncable` doesn't. The provider accepts either consumer, so
switching takes one import:

```js
import { createConsumer } from "@anycable/web"
```

Cursor and selection traffic grows with every pointer move. With whispers, the
Go server relays it between clients and it never becomes an RPC call into Ruby.

## Threads and the GVL

You can share a `Doc` across Ruby threads (Puma threads, Action Cable
connection threads, background jobs) without adding your own locks.
`test/thread_safety_test.rb` runs shared docs, the full sync handshake, and
fan-in sync across 8 threads at once, and checks that the interleaving doesn't
change convergence.

Every method that does real CRDT work releases the Global VM Lock while the
native code runs. That means CRDT work runs in parallel across Ruby threads on
MRI, and you don't need JRuby or TruffleRuby to get it.
`bench/parallelism_bench.rb` measures more than a 2x wall-clock speedup when
applying a roughly 900 KB update concurrently. A thread applying a large update
holds the doc's write lock but not the GVL, so other Ruby threads keep running.

Each of those methods follows the same steps. It copies the Ruby byte strings,
releases the GVL, and does the yrs work, taking and releasing the native locks
inside that step. Then it takes the GVL back and builds the Ruby objects. Ruby
APIs are only called while holding the GVL, and no native lock is held while
reacquiring it, so the locks can't deadlock. A panic in native code is caught
and re-raised as a Ruby exception.
