# yrby site

The documentation and live-demo site for [yrby](https://github.com/jpcamara/yrby).
A Rails app with no database, no Redis, and no shared state — every demo room is
a Yjs document in one process's memory, behind the channel's `on_load` and
`on_change` hooks.

It runs on the **published** packages, not on the checkout it sits inside:
`yrby` and `yrby-rails` from RubyGems, `yrby-client` from npm. If a page here
works, it works from a fresh `gem install`.

```
site/
├── app/lib/           the store, the limiters, the demo list, the docs model
├── app/channels/      DocumentChannel and the connection
├── config/limits.rb   every rate, size, and count limit, with its reasoning
├── docs/              the documentation pages, as markdown
├── frontend/          bun build for the demo bundles + the e2e harness
└── test/              store, throttles, controllers
```

## Running it

The app pins Ruby 3.4.5 in `.ruby-version`, so rbenv resolves it from inside
this directory with no prefix. (The repo's parent directory pins 3.4.7, which is
not installed on this machine; if you run a command from above `site/` you will
need `RBENV_VERSION=3.4.5` in front of it.)

```bash
bundle install
cd frontend && bun install && bun run build && cd ..
bundle exec falcon serve --bind http://localhost:3000 --count 1
```

Falcon is the only server in the Gemfile — there is no Puma here, so `bin/rails
server` has nothing to boot. `frontend/boot_server.sh` is the same command with
a health wait and a pidfile.

Tests:

```bash
bin/rails test
cd frontend && bun run lint
```

Two-browser end to end, against a real server:

```bash
cd frontend
PORT=3888 SERVER_PIDFILE=/tmp/site.pid ./boot_server.sh
PORT=3888 node site_e2e.mjs
kill "$(cat /tmp/site.pid)"
```

Nothing here needs Postgres or Redis, including the tests.

## The store

`app/lib/room_store.rb` is the whole storage layer: a `Hash` of rooms, each
holding a compacted snapshot plus a tail of raw updates.

```ruby
on_load  { |key|         RoomStore.current.load(key) }
on_change { |key, update| RoomStore.current.append(key, update) }
```

`load` replays the snapshot and the tail into a fresh `Y::Doc` and returns
`encode_state_as_update`, which is lossless: an update that arrived before the
update it depends on stays as a pending struct and still heals when the missing
one lands. Every 32 appends the tail is folded into `compacted_state_update` —
and folding is skipped while `doc.pending?`, because a snapshot must not carry a
gap. That is the same rule the bundled `Y::Document` store follows, for the same
reason.

Rooms are ephemeral by design. They are dropped after 20 minutes with nobody in
them, and lost entirely when the process restarts. A browser still holding the
document re-seeds the server through the ordinary sync handshake, so a room
whose tab is open survives a restart; a room whose tabs are all closed does not.

## Why one process

The store is not shared, and the Action Cable adapter is `async`, which is
in-process. Two processes would serve different documents under the same URL and
broadcasts would not cross between them. So the app is one process everywhere:
`--count 1` under Falcon, one machine on Fly, one container under Kamal.

That is a property of this store, not of yrby. Swapping `RoomStore` for a shared
one and `async` for `redis` or `solid_cable` is all a multi-process deployment
needs — the channel is unchanged. See
[Storage](https://github.com/jpcamara/yrby/blob/main/README.md#actioncable-integration)
in the repo README.

Falcon rather than Puma because the resource this app spends is held
connections, not request throughput. A WebSocket costs a fiber instead of a
pooled thread, so one process holds far more of them.

## Throttling

A public collaborative demo is an open write surface: anyone can open a socket
and send frames, with no account and no rate limit of their own. Seven layers
bound it. Every number lives in `config/limits.rb` with the reasoning next to
it; the table below is the summary.

| Layer | Limit | Value | Why |
|---|---|---|---|
| 1. Rack::Attack | page requests per IP | 60 / minute | A reader loads a page every few seconds. Static files and `/up` are not counted, so one page load isn't a dozen hits. |
| 1. Rack::Attack | cable handshakes per IP | 12 / minute | The expensive request: it upgrades and holds a connection. Counted separately so a reconnect storm can't lock a reader out of the docs. |
| 2. Connection | concurrent sockets per IP | 8 | "Open a second window" is the demo, and a visitor may open one per page. Past that it is a script. |
| 2. Connection | concurrent sockets, process-wide | 500 | Roughly 25 MB of connection overhead at ~50 KB each. |
| 3. Token bucket | frames per second, per subscription | 40, burst 120 | Typing plus awareness at pointer-event rate is well under this. The burst absorbs what arrives together at join. |
| 3. Token bucket | dropped frames before the socket closes | 200 | Bursts of drops are normal during a fast drag. A client that keeps going past this is not a person. |
| 4. Frame size | bytes per frame | 128 KiB | yrby's own default is 8 MiB, sized for a real app's initial `SyncStep2`. Demo documents are tiny. |
| 5. Document size | bytes per room | 512 KiB | About ten times a realistic demo document. At the cap the room goes read-only and says so. |
| 6. Room caps | peers per room | 12 | More than a dozen carets is unreadable, and each peer is another fan-out target. |
| 6. Room caps | live rooms, process-wide | 200 | 200 x 512 KiB is a 100 MB ceiling on the store. |
| 7. Eviction | idle time before a room is dropped | 20 minutes | Long enough that closing a tab and coming back with the link still finds the document. |

A few of these are worth explaining rather than tabulating.

**Rate limiting is not frame validation.** yrby already validates every frame as
a single well-formed protocol message and drops anything malformed, truncated,
multi-message, or oversized. That says nothing about volume. A client sending
perfectly valid updates as fast as it can is still a denial of service, so the
token bucket sits in `receive` in front of `sync_receive`.

**A full room goes read-only, it does not raise.** The obvious way to enforce a
document size cap is to raise from `on_change`. That is wrong here: a raising
`on_change` rejects the update without acking it, and an unacked update is
retransmitted forever, because the protocol has no negative ack. So the channel
checks `full?` *before* handing the frame to yrby, drops it there, and transmits
a one-time `{ "notice": "document_full" }` that the page turns into "open a new
room". The store's own `DocumentFull` is a backstop for a bug, not the routine
path. Awareness frames still flow in a frozen room, so presence keeps working.

**Idle eviction is what keeps ordinary traffic away from the room cap.** Every
visitor mints a room and most are abandoned within a minute. Without the sweeper
(`app/lib/room_sweeper.rb`, one thread, a sweep a minute) the 200-room ceiling
would be reached by normal use rather than by abuse.

**No uploads, anywhere.** The site accepts no files. A public, anonymous write
surface plus a file endpoint is a free file host, and every one of the throttles
above is about bounding what a stranger can spend — bytes on disk or in an
object store are not a resource this app should be handing out at all. So the
policy is structural rather than a limit to tune:

- Active Storage is not installed. The Gemfile lists the six Rails frameworks
  this app requires instead of the `rails` meta-gem, so there is no upload
  engine in the image and nothing to mount by accident.
- There are no upload routes, no direct-upload endpoints, and no multipart
  handling.
- The rich-text demo is Tiptap's StarterKit only. There is no Image extension,
  so the editor's schema has no node a file could become. The Lexxy page in
  `examples/actioncable-demo`, which does wire up Active Storage and
  direct upload, was deliberately not ported.
- Files are refused before any editor sees them. `frontend/src/room.js`
  cancels `paste`, `drop`, and `dragover` events carrying files, in the capture
  phase on `document`, on every demo page; the Tiptap editor additionally
  returns "handled" from its own `handlePaste`/`handleDrop` for the same events.
  Text pastes are untouched.

**The counters are process-local**, which is correct here for the same reason
the store is: one process. Rack::Attack's cache is an
`ActiveSupport::Cache::MemoryStore`. In front of several processes all of this
would have to move to a shared cache — and, honestly, most of it should move to
the CDN.

## Caching

Docs pages are server-rendered markdown with nothing per-visitor in them, so
they are sent as

```
cache-control: public, max-age=3600, stale-while-revalidate=86400
```

A CDN answers for an hour, then keeps answering from the stale copy while it
refreshes in the background. A deploy never sends a wave of misses at a single
process, and a restart is invisible to readers. Demo pages are `no-store` —
they're bound to a room, and the room is where the state is.

## Hosting

Both deployment configs are here; they are alternatives, not a stack.

**Fly.io** (`fly.toml`): one `shared-cpu-1x` machine with 1 GB, `auto_stop_machines`
and `auto_start_machines` on, and `min_machines_running = 0`. Scale to zero fits
a demo that is idle most of the time, and it interacts with the in-memory store
in exactly the way you would expect: a stopped machine has lost every room.
`auto_stop_machines = "suspend"` keeps the memory image, so a resumed machine
still has them and comes back in well under a second, but a full stop is always
possible and must be assumed. Ephemeral rooms make that acceptable; nothing you
would miss belongs in this app. Roughly **$2-4/month** at low traffic, most of
it the 1 GB of memory while the machine is awake.

**A VPS with Kamal** (`config/deploy.yml`): one host, one container, kamal-proxy
terminating TLS. A Hetzner CX22 (2 vCPU, 4 GB) is about **€4/month** flat, and
holds far more concurrent connections than the machine above. No scale to zero,
so rooms survive between visitors, and you own the box and its updates.

**Cloudflare's free tier in front of either.** It is worth doing for both
reasons: the docs pages become a CDN hit and never reach the app, and the free
plan absorbs volumetric attacks that would otherwise arrive at one small
machine. WebSockets pass through on the free plan, so the demos keep working —
just leave the cable path uncached, which it is, because those responses are
`no-store`. Set `CABLE_ALLOWED_ORIGINS` once the domain is settled so the
handshake is locked to it.

I would deploy this on Fly. The app is one process either way, and the thing
that actually differs is what you spend attention on: Fly's config is the whole
operational surface, where the VPS is a host to keep patched. Scale to zero also
matches the traffic shape — a docs site with occasional demo visitors — and the
in-memory store gives it up cheaply, because these rooms are meant to be
thrown away. The VPS wins if the demos ever need to hold hundreds of
simultaneous connections, where 4 GB for €4 is hard to argue with.

## Capacity

The number that matters for a demo site is concurrent WebSocket connections, and
the app caps it at 500 (`MAX_CONNECTIONS`).

Where that comes from: under Falcon each connection is a fiber, a socket, and an
Action Cable connection object, which is roughly 50 KB together — call it 25 MB
at the cap. Rails plus the yrby native extension is 150-200 MB resident. The
store's own ceiling is 200 rooms at 512 KiB, so 100 MB. That is about 350 MB of
worst case inside a 1 GB machine, with the rest as headroom for the CRDT work
itself: applying an update allocates, and `on_load` replays a room's log into a
fresh `Y::Doc` on every handshake.

CPU is the softer limit and the one that would bite first in practice. Every
frame is a native CRDT apply, and yrby releases the GVL for it, so a
`shared-cpu-1x` can genuinely parallelize — but 500 people typing at once on one
shared vCPU is not a thing this machine does well. Realistically it is
comfortable in the low hundreds of *connected* clients with a handful actively
editing, which is what a demo site sees. The 500 cap is there so the failure
mode is a refused connection rather than a machine that swaps and dies.

I have not load-tested this app at those numbers. The estimate is arithmetic
from per-connection cost, not a measurement. The repo's demo app has a
`loadtest.mjs` and a `stress.mjs` that would answer it properly.

## Docs pages

`docs/*.md`, rendered at request time by `app/lib/doc_page.rb` (Commonmarker,
GFM). The nav order and the README anchor each page came from are in
`DocPage::PAGES`; the page title is the file's first `#` heading, so it can't
fall out of step with the content.

The repo README is canonical. These pages are a copy of it and copies drift, so
every page says so and links back to the section it came from. When the README
changes, update the matching page here.

## Demos

Five pages, chosen for breadth of Yjs shape rather than for count:

| Page | Shape | What it shows |
|---|---|---|
| Rich text | `Y.XmlFragment` | Tiptap with remote carets, bound by Tiptap's own Collaboration extension |
| Spreadsheet | `Y.Array` of row `Y.Map`s, cells nested | Cell-level merges; sorting kept out of the document |
| Whiteboard | `Y.Map` | Records in a map — the shape canvas tools keep |
| Kanban | `Y.Array` | A move is one `map.set`, so concurrent moves never conflict |
| Code | `Y.Text` | CodeMirror 6 with remote cursors and selections |

They are ports of the pages in
[`examples/actioncable-demo`](../examples/actioncable-demo), with the provider
setup, presence chips, status line, and room bar lifted into
`frontend/src/room.js` so each demo file is only its Yjs binding.

Every visitor lands in a fresh room (`/demos/tiptap` mints one and redirects).
The room id is shared across the demo nav, so switching pages keeps you in the
same room with a different document key.

`frontend/src/room.js` also wraps the Action Cable consumer so the page can read
the server's `{ notice: ... }` envelopes. `yrby-client`'s provider ignores
envelopes it doesn't recognize, and the mixin it builds closes over the provider
rather than `this`, so composing a `received` handler around it is safe.

### Building the bundles

```bash
cd frontend && bun run build     # or bun run watch
```

One entry per demo, output to `public/<slug>.js`, which the page loads by slug.
The build pins `yjs`, `y-protocols`, and `lib0` to one canonical path. Two
copies of `yjs` in one bundle is the failure that costs the most time to find:
the provider and the editor binding end up on different `Y.Doc` internals,
y-prosemirror throws "Method unimplemented" applying remote updates, and nothing
about the symptom points at module resolution. The long comment at the top of
`build.mjs` has the details.

## What this app is not

It is a demo of yrby, not a template for a production collaborative app. The
things it does differently from one:

- No authentication. Rooms are public and anonymous, and anyone with the link
  can edit.
- No durability. There is no database; documents live in memory and are
  deliberately thrown away.
- One process. Everything above follows from that.

`examples/actioncable-demo` in this repo is the other end: Postgres, AnyCable,
multi-process, and the full test and load suites.
