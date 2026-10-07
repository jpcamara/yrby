# AnyCable and multi-process

Most Rails apps run several processes, and any of them might handle a given
document. Two things keep them in sync.

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

The demo app's `multiprocess.mjs` test runs clients against two processes. It
checks that every client ends up with the same document, that both processes
read the latest state, that presence reaches clients on the other process, and
that both processes write to the same log.

## AnyCable

yrby works on AnyCable. The demo app tests it against a real anycable-go
server and RPC server in `frontend/anycable_probe.mjs` and
`frontend/anycable_concurrent.mjs`. Those scripts check that the connection
stays up, that a different process can read the latest state, and that
concurrent edits end up the same everywhere.

This site runs the smallest possible AnyCable setup.
[anycable-thruster](https://github.com/anycable/thruster) bundles anycable-go
into the Thruster proxy, so `thrust bin/serve` starts everything. The Go
server handles `/cable` and calls Rails over HTTP at a path AnyCable mounts in
the app, and Rails sends broadcasts back over localhost. On one machine there's
no Redis and no separate RPC process. The
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

That's why every channel example in these docs passes the key to
`sync_receive`. When anycable-rails is loaded, the gem's `Y::DocumentChannel`
stores the authorized key as channel state, and looks the record up again from
the token when it needs it. On plain Action Cable an instance variable would
work, but the examples are written to run on both.

### Connection-scoped state has to be declared

If you keep a temporary document on the connection, declare it as channel
state with `state_attr_accessor` from anycable-rails. Base64-encode the bytes,
because AnyCable sends that state as JSON with every RPC call:

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

On AnyCable, the channel opens a second stream for presence with
`whisper: true`. A whisper goes from one browser to the others through
anycable-go. Only presence uses it. Document edits still go through the
server, which saves and confirms them.

Plain Action Cable has no whispers, so presence goes through the server too.
Your channel code doesn't change, because the concern checks whether whispers
are available.

In the browser, the provider whispers presence when the subscription has a
`whisper` method. Consumers from `@anycable/web` have one, and
`@rails/actioncable` consumers don't. The provider takes either, so switching
is one import:

```js
import { createConsumer } from "@anycable/web"
```

Every cursor move sends presence. With whispers, the Go server relays those
between browsers, and none of them turn into a call into Ruby.

## Threads and the GVL

You can share a `Doc` across Ruby threads (Puma threads, Action Cable
connection threads, background jobs) without adding locks.
`test/thread_safety_test.rb` runs shared docs and full sync handshakes from 8
threads at once, and checks that every thread still ends up with the same
document.

Methods that do real CRDT work release the Global VM Lock while the native
code runs. So CRDT work runs in parallel on regular MRI, and you don't need JRuby or
TruffleRuby for it. `bench/parallelism_bench.rb` shows more than a 2x speedup when
applying a roughly 900 KB update on several threads at once. A thread applying
a large update holds the doc's write lock but not the GVL, so other Ruby
threads keep running.

Each of those methods works the same way. It copies the Ruby strings it needs,
releases the GVL, and does the yrs work, taking and releasing native locks
along the way. Then it takes the GVL back and builds the Ruby objects. Ruby is
only called while holding the GVL, and no native lock is held while waiting
for it, so the two can't deadlock. If the native code panics, Ruby raises an
exception.
