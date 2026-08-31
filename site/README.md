# yrby site

The documentation and live-demo site for [yrby](https://github.com/jpcamara/yrby).
A Rails app whose demo rooms run the exact storage stack the docs teach:
`Y::Document.load_state` / `Y::Document.append` — the gem's own models — on a
SQLite file. No Postgres, no Redis, and nothing authoritative in process memory
between messages.

WebSockets are served by [anycable-thruster](https://github.com/anycable/thruster):
Thruster with anycable-go embedded in the proxy. `thrust bin/serve` runs the
proxy, the AnyCable server, and Falcon as one command. Go holds every socket and
calls back into Rails over HTTP RPC, so the Ruby side only ever handles a short
request.

It runs on the **published** packages, not on the checkout it sits inside:
`yrby` and `yrby-rails` from RubyGems, `yrby-client` from npm. If a page here
works, it works from a fresh `gem install`.

```
site/
├── app/lib/           the caps, the limiters, the demo list, the docs model
├── app/channels/      DocumentChannel and the connection
├── config/limits.rb   every rate, size, and count limit, with its reasoning
├── db/                the vendored yrby:tables migration + schema
├── docs/              the documentation pages, as markdown
├── frontend/          bun build for the demo bundles + the e2e harness
└── test/              caps, throttles, sweeper, controllers
```

## Running it

The app pins Ruby 3.4.5 in `.ruby-version`, so rbenv resolves it from inside
this directory with no prefix. (The repo's parent directory pins 3.4.7, which is
not installed on this machine; if you run a command from above `site/` you will
need `RBENV_VERSION=3.4.5` in front of it.)

```bash
bundle install
cd frontend && bun install && bun run build && cd ..
PORT=3000 frontend/boot_server.sh
```

`boot_server.sh` sets the AnyCable environment, runs `thrust bin/serve`, waits
until both the pages and the cable answer, and writes a pidfile. `bin/serve` is
the upstream half of the thrust contract: thrust sets `PORT` to its
`TARGET_PORT` before spawning its command, and the script translates that into
Falcon's `--bind`. Running Falcon on its own gets you the pages and no
WebSocket: Rails' own `/cable` mount is turned off, because the cable belongs to
the Go server in the proxy.

On macOS, export `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` first if you boot by
hand. Falcon forks its worker from the controller process, and macOS refuses to
fork after certain Objective-C runtime initialization; without it the worker
dies at boot and every request comes back as a connection reset.
`boot_server.sh` sets it for you.

Tests:

```bash
bin/rails test
cd frontend && bun run lint
```

Two-browser end to end, against the full stack — proxy, embedded AnyCable, and
Falcon, exactly as deployed:

```bash
cd frontend
PORT=3888 SERVER_PIDFILE=/tmp/site.pid ./boot_server.sh
PORT=3888 node site_e2e.mjs
kill "$(cat /tmp/site.pid)"
```

Nothing here needs Postgres or Redis, including the tests — the database is a
SQLite file under `storage/`, created by `db:prepare` (boot_server.sh runs it).

## The store

The store is the one the docs teach, verbatim:

```ruby
on_load { |key| Y::Document.load_state(key) }
on_change do |key, update|
  Y::Document.append(key, update)
  Rooms.current.note_append(key, update.bytesize) # the site's size cap
end
```

`Y::Document` and `Y::DocumentUpdate` ship in the yrby-rails gem; the vendored
`yrby:tables` migration in `db/migrate` creates their tables on SQLite (one
file under `storage/`, on a mounted volume in production). Everything that used
to be hand-rolled here is now the gem's: loads are lossless (a causally-gapped
update rides along as a pending struct and heals), compaction folds the tail
every 64 rows with gapped rows quarantined rather than dropped, and nothing
authoritative is held in process memory between messages — an idle room costs a
few rows on disk and ~zero RAM.

That last property is the point of the change. The store-backed concern
rebuilds state from the database per message, so the number of rooms is bounded
by disk, not by what one Ruby process can hold. It also makes the site a live
demonstration of the documented API instead of a bespoke store: what the
[Storage](/docs/storage) page describes is literally what is running.

What the site adds around the hooks lives in `app/lib/rooms.rb` — seats, caps,
and a cached size check — and `app/lib/room_sweeper.rb`, the TTL eviction.

Rooms are temporary by policy, not by accident of memory. Documents survive
restarts and deploys now (they are rows on a volume); the sweeper deletes rooms
untouched for 24 hours. That TTL is a content decision — these are public,
anonymous, unmoderated documents, and "temporary" is a promise the site makes
about them — so it stays even though RAM no longer forces it.

## The stack

```
browser ──ws──► thrust (Go) ──HTTP RPC──► Falcon ──► DocumentChannel ──► Y::Document
        ──http─►    │                                                    (SQLite)
                    └──► Falcon (pages)
```

`thrust bin/serve` is one command and one container. Inside it, anycable-go owns
`/cable`, proxies everything else to Falcon, and calls Rails back at
`/_anycable` — the HTTP RPC endpoint AnyCable mounts in the app — for connect,
subscribe, and every message. Rails hands broadcasts back to the Go server over
localhost. No Redis in either direction, because there is one node.

The split matters for what this site costs to run. Ruby holds nothing between
messages: a connected-but-idle client is a goroutine in Go, not a thread or an
object in Ruby. And awareness never reaches Ruby at all — see Presence below.

### Why Falcon behind the proxy

The Ruby side's whole workload is short HTTP requests — page renders and RPC
calls — which is the fiber reactor's home ground: no thread pool to size, and a
request that blocks on IO yields instead of holding a worker. It also dogfoods
the server yrby's own CI proves the native extension under. The demo app's e2e
suite boots under both Puma and Falcon deliberately, and this site is the Falcon
deployment of that pair, running the same extension inside the fiber scheduler
in production shape.

### Why one process

Falcon runs with `--count 1`, always; `bin/serve` refuses to boot with anything
else. Worth saying plainly: **with SQLite behind the hooks, single-process is no
longer a correctness requirement for the documents.** The store is shared on
disk, broadcasts already fan out through the embedded Go server, and WAL-mode
SQLite handles concurrent processes on one box — the gem's store-backed design
is exactly what makes scaling out possible. What still assumes one process is
the throttle bookkeeping: Rooms' seats and size cache, ConnectionLimiter, and
Rack::Attack's counters are all process memory, and two workers would each
enforce their own half-sized caps. One process keeps the accounting honest and
the app simple, and a demo site does not need more. Scaling out for real means
moving those counters to a shared cache (and probably the database to Postgres).

Because sockets terminate in Go, a fresh channel instance is built for every
command and instance variables do not survive between them. Everything the
channel has to remember — its seat in the room, its token bucket, whether it has
sent the full-room notice — is declared with `state_attr_accessor` and travels
as JSON in the RPC exchange. The key is passed to `sync_receive` on every call
for the same reason. This is the AnyCable shape yrby's README documents, and the
site is a working example of it.

### Concurrency safety

Under Falcon the RPC requests are fibers, mostly on one thread, switching at IO
and scheduler yields rather than preemptively. Document writes are the
database's problem now — SQLite in WAL mode with Rails' busy timeout — but the
site's own bookkeeping (`Rooms`' seats and size cache, `ConnectionLimiter`)
still takes explicit locks: a fiber can yield anywhere IO happens, the reactor
is free to serve requests concurrently, the sweeper is a real `Thread`, and an
uncontended mutex costs nothing. DB reads happen outside the locks so a fiber
never yields into SQLite while holding one. The code is correct under
preemptive threads too, which is what the test suite runs it under.

## Throttling

A public collaborative demo is an open write surface: anyone can open a socket
and send frames, with no account and no rate limit of their own. Eight layers
bound it. Every number lives in `config/limits.rb` with the reasoning next to
it; the table below is the summary.

| Layer | Limit | Value | Why |
|---|---|---|---|
| 0. anycable-go | bytes per WebSocket frame | 128 KiB | Refused at the socket, in Go, so an over-size frame never becomes an RPC call. `ANYCABLE_MAX_MESSAGE_SIZE`. |
| 1. Rack::Attack | page requests per IP | 60 / minute | A reader loads a page every few seconds. Static files, `/up`, and the RPC endpoint are not counted. |
| 2. Connection | concurrent sockets per IP | 8 | "Open a second window" is the demo, and a visitor may open one per page. Past that it is a script. |
| 2. Connection | concurrent sockets, process-wide | 500 | A held socket is a goroutine in Go, not an object in Ruby, so this is roughly 5-10 MB. A conservative ceiling, not a memory limit. |
| 3. Token bucket | frames per second, per subscription | 40, burst 120 | Typing plus awareness at pointer-event rate is well under this. The burst absorbs what arrives together at join. |
| 3. Token bucket | dropped frames before the socket closes | 200 | Bursts of drops are normal during a fast drag. A client that keeps going past this is not a person. |
| 4. Frame size | bytes per frame | 128 KiB | yrby's own default is 8 MiB, sized for a real app's initial `SyncStep2`. Demo documents are tiny. |
| 5. Document size | bytes per room | 512 KiB | About ten times a realistic demo document. At the cap the room goes read-only and says so. |
| 6. Room caps | peers per room | 12 | More than a dozen carets is unreadable, and each peer is another fan-out target. |
| 6. Room caps | documents on disk | 2000 | 2000 x 512 KiB bounds the database file at about 1 GB — a disk cap now, not RAM. |
| 7. Eviction | idle time before a room is deleted | 24 hours | A content decision: rooms are public and anonymous, and "temporary" is a promise. A link shared in the morning still works after dinner. |

There is no cable-handshake throttle in Rack::Attack any more. `/cable` never
passes through Rack — the embedded Go server answers it in the proxy — so a
limit there would count nothing. What bounds handshakes instead is the per-IP
connection cap, which runs in Ruby on the Connect RPC. The RPC endpoint itself
is safelisted: every WebSocket command arrives there, so throttling it by IP
would throttle the site.

There is no cable-handshake throttle in Rack::Attack any more. `/cable` never
passes through Rack — the embedded Go server answers it in the proxy — so a
limit there would count nothing. What bounds handshakes instead is the per-IP
connection cap, which runs in Ruby on the Connect RPC. The RPC endpoint itself
is safelisted: every WebSocket command arrives there, so throttling it by IP
would throttle the site.

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
checks the cap *before* handing the frame to yrby, drops it there, and transmits
a one-time `{ "notice": "document_full" }` that the page turns into "open a new
room". Awareness frames still flow in a frozen room, so presence keeps working.

The cap's implementation changed with the store. The true size — snapshot bytes
plus tail bytes — is a SUM over rows, too expensive per frame and too slow to
poll (a flood could append megabytes between polls). So `Rooms` keeps a cached
size per room that `note_append` bumps the moment each update is recorded,
which holds the cap tight at any write rate with no query on the hot path; the
database is re-read only when the cache entry is stale (30 s), to pick up
compaction. Compaction only shrinks the true size, so between refreshes the
cache can only over-estimate — the safe direction for a cap. Worst case, a
just-compacted room stays read-only a few extra seconds.

**Idle eviction is what keeps ordinary traffic away from the room cap.** Every
visitor mints a room and most are abandoned within a minute. Without the sweeper
(`app/lib/room_sweeper.rb`, one thread, a sweep every five minutes) the
2000-document ceiling would be reached by normal use rather than by abuse. A
room is stale when it has no write inside the TTL and nobody in it; occupied
rooms are never evicted. The same sweep reaps leaked connection slots: the
per-IP cap frees a slot on the Disconnect RPC, but that RPC can fail to arrive
(a dropped socket, a partition), so a slot older than an hour is treated as
leaked and reclaimed. Reaping only ever loosens the cap, never rejects wrongly.

**No uploads, anywhere.** The site accepts no files. A public, anonymous write
surface plus a file endpoint is a free file host, and every one of the throttles
above is about bounding what a stranger can spend — bytes on disk or in an
object store are not a resource this app should be handing out at all. So the
policy is structural rather than a limit to tune:

- Active Storage is not installed. The Gemfile lists the Rails frameworks this
  app requires — Active Record among them, for the document store — instead of
  the `rails` meta-gem, so there is no upload engine in the image and nothing
  to mount by accident.
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

**Fly.io** (`fly.toml`): one `shared-cpu-1x` machine with 1 GB and a 1 GB
volume for the database, `auto_stop_machines` and `auto_start_machines` on, and
`min_machines_running = 0`. Scale to zero fits a demo that is idle most of the
time, and with the documents in SQLite on the volume a stopped machine loses
nothing: a returning visitor's link still works, and rooms expire on the
sweeper's clock, not the machine's. Roughly **$2-4/month** at low traffic.

**A VPS with Kamal** (`config/deploy.yml`): one host, one container, kamal-proxy
terminating TLS, the database on a named Docker volume. A Hetzner CX22 (2 vCPU,
4 GB) is about **€4/month** flat, holds far more concurrent connections than the
machine above, and you own the box and its updates.

**Cloudflare's free tier in front of either.** It is worth doing for both
reasons: the docs pages become a CDN hit and never reach the app, and the free
plan absorbs volumetric attacks that would otherwise arrive at one small
machine. WebSockets pass through on the free plan, so the demos keep working —
just leave the cable path uncached, which it is, because those responses are
`no-store`.

### Secrets and origins

Kamal reads secrets from `.kamal/secrets` (gitignored). Copy the committed
template and fill it in — or, better, have each line pull from a password
manager so nothing sensitive lands on disk:

```bash
cp .kamal/secrets.example .kamal/secrets
# SECRET_KEY_BASE=$(openssl rand -hex 64)      — Rails signing key
# ANYCABLE_SECRET=$(openssl rand -hex 32)      — configures both cable halves
```

`config/deploy.yml` lists those two under `env.secret`, so they reach the
container as environment without ever being written into the committed YAML. On
Fly they are `fly secrets set …` instead. The SQLite volume is `chmod 700` in
the image, so the database (ephemeral room content) is readable only by the app
user.

Once the domain is settled, lock the WebSocket origin: set `ALLOWED_ORIGINS`
(comma-separated full origins, e.g. `https://yrby.dev`) in the deploy env. One
value drives both halves of the cable — the entrypoint strips the scheme into
`ANYCABLE_ALLOWED_ORIGINS` for the embedded anycable-go, which 403s a mismatched
handshake at the socket, and Rails re-checks the Origin on the Connect RPC.
Behind Cloudflare it also makes `request.ip` the real visitor: `trusted_proxies`
vendors Cloudflare's ranges (plus loopback and the container-internal ranges,
but deliberately not `192.168.0.0/16`, so a LAN client can't forge
`X-Forwarded-For` to escape a throttle bucket), and Rack::Attack keys on that.
Left unset, all of this is permissive — which is what the plain-http Pi on the
LAN wants.

Either way it is one machine and one container: the database volume attaches to
one box, and the throttle counters assume one process. For a demo site that is
the right trade — a bigger box is a one-line change, and everything a reader is
here to see works the same on one process as on fifty.

Both configs stay in the repo; the site is deployed with Kamal on Hetzner. The
€4 box's 4 GB and steady disk suit a database-backed app better than paying for
wake-ups, and no scale-to-zero means no cold starts in front of a demo. Fly
remains the config to grab if you want the same site with zero server
ownership.

One proxy-level cap worth noting: `MAX_REQUEST_BODY=65536` in thrust's
environment. Every public route is a GET, so 64 KB of request body is generous.
It does not constrain AnyCable — the embedded Go server dials Falcon's port
directly for RPC and takes broadcasts on its own listener, so neither path
crosses thrust's public handler. Verified against thruster's source
(`internal/service.go`): the body cap wraps only the inbound proxy.

## Capacity

The number that matters for a demo site is concurrent WebSocket connections, and
the app caps it at 500 (`MAX_CONNECTIONS`).

Where that comes from: a held socket lives in anycable-go, not in Ruby. It is a
goroutine plus its read and write buffers, on the order of 10 KB, so 500 of them
is 5-10 MB. Ruby holds nothing per connection between messages — the channel
object is built for a command and thrown away — so an idle client costs Rails
zero. Documents cost RAM only while being loaded or applied: they live in
SQLite, and the room caps (2000 documents at 512 KiB) bound the database file
at about 1 GB of disk, not memory. What stays resident is Rails plus the yrby
native extension, 150-200 MB. The rest of a 1 GB machine is headroom for the
CRDT work in flight: applying an update allocates, and `on_load` replays a
room's snapshot and tail into a fresh `Y::Doc` per handshake.

So the 500 cap is not where memory runs out. It is a deliberately conservative
number, set so the failure mode at load is a refused connection rather than a
machine that swaps and dies. On memory alone the Go side would hold several
thousand.

CPU is the real limit, and it is Ruby's. Every document frame is an RPC call
into the Falcon reactor and a native CRDT apply. yrby releases the GVL for that
work — the fiber scheduler keeps serving while the native code runs — but 500
people typing at once on one shared vCPU is not a thing this machine does
well. SQLite adds a
write per update and a read per load on the same box, which at demo scale is
noise under WAL. Presence is the part that does not count: awareness is whispered client-to-client by Go and
never reaches Ruby, which is exactly the traffic that would otherwise scale with
pointer movement. Realistically this is comfortable holding several hundred
*connected* clients with a few dozen actively editing, which is what a demo site
sees.

I have not load-tested this app at those numbers. The estimate is arithmetic
from per-connection cost, not a measurement, and the split between what Go holds
and what Ruby does is the part I would want measured first. The repo's demo app
has a `loadtest.mjs` and a `stress.mjs` that would answer it properly.

## Docs pages

`docs/*.md`, rendered at request time by `app/lib/doc_page.rb` (Commonmarker,
GFM). The nav order and the README anchor each page came from are in
`DocPage::PAGES`; the page title is the file's first `#` heading, so it can't
fall out of step with the content.

The repo README is canonical. These pages are a copy of it and copies drift, so
every page says so and links back to the section it came from. When the README
changes, update the matching page here.

## Demos

Six pages, chosen for breadth of Yjs shape rather than for count:

| Page | Shape | What it shows |
|---|---|---|
| Rich text | `Y.XmlFragment` | Lexxy over the published lexxy-realtime stack: sgid auth, a record-backed document, and the server rendering `note.body` via `Y::Lexxy` |
| Tiptap | `Y.XmlFragment` | The same shape through Tiptap's own Collaboration extension |
| Spreadsheet | `Y.Array` of row `Y.Map`s, cells nested | Cell-level merges; sorting kept out of the document |
| Whiteboard | `Y.Map` | Records in a map — the shape canvas tools keep |
| Kanban | `Y.Array` | A move is one `map.set`, so concurrent moves never conflict |
| Code | `Y.Text` | CodeMirror 6 with remote cursors and selections |

### The Rich text demo is the flagship stack, end to end

The Lexxy page runs the published `lexxy-realtime` gem (0.7.0) and npm package
(0.6.0) the way a real app would, not a special demo build:

- **The record shape.** Each room is a `Note` (find-or-created by room id).
  `has_collaborative_rich_text :body` comes from the gem's Collaborative
  concern, which capability-detects Action Text — this app has none, so the
  concern takes its plain-column path and `refresh_collaborative_rich_text`
  writes the `Y::Lexxy`-rendered HTML straight into `notes.body`. The page's
  "Stored HTML" panel reads that column back over a GET-only JSON endpoint:
  server-rendered markup, no browser in the loop.
- **The auth shape.** The page mints a signed GlobalID scoped to
  `lexxy_realtime/body` — the gem's purpose format — and `NoteChannel` (the
  generated channel template plus this site's throttle layers) locates the
  record through it. A token for another purpose or field does not locate,
  and the subscription is rejected. `authorized?` returns true because the
  rooms are public; the sgid scoping is intact and tested.
- **The composition API.** The client uses the npm README's "create the
  provider yourself" path: `room.js` builds the yrby-client provider (over
  `@anycable/web`, with the room bar and full-room notice), and the
  `<lexxy-collaboration>` element receives `doc` and `provider` instead of
  creating its own cable.
- **One `lexical`.** The bundle pins `lexical` and `@lexical/yjs` as
  singletons next to the yjs family — two copies break node-class identity
  the same way two yjs copies break constructor checks (`build.mjs`).
- **One deliberate cut.** The gem itself is `require: false`: its engine
  loads the Lexxy gem's engine, which wires Action Text helpers in
  `to_prepare` and cannot boot without Action Text. The app requires only
  `lexxy_realtime/collaborative` — the concern is self-contained — and
  mirrors the gem's one-line sgid purpose format. The ERB form helper
  (`collaborative_rich_textarea`) is part of what stays unloaded, so the
  page renders the `<lexxy-editor>` element directly.

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

### Building the bundles and the stylesheet

```bash
cd frontend && bun run build     # JS bundles + CSS
bun run watch                    # rebuild bundles on change
bun run watch:css                # rebuild the stylesheet on change
```

One entry per demo, output to `public/<slug>.js`, which the page loads by slug.
The build pins `yjs`, `y-protocols`, and `lib0` to one canonical path. Two
copies of `yjs` in one bundle is the failure that costs the most time to find:
the provider and the editor binding end up on different `Y.Doc` internals,
y-prosemirror throws "Method unimplemented" applying remote updates, and nothing
about the symptom points at module resolution. The long comment at the top of
`build.mjs` has the details.

## Frontend styling

Tailwind v4, through the same bun toolchain as the bundles: `bun run build:css`
compiles `frontend/css/site.css` to `public/site.css` (a few KB gzipped,
purged), served as a plain static file. There is no asset pipeline — Propshaft
is gone, and everything the browser loads is a file bun built.

The design is dark-only: zinc-950 background, one ruby accent for links, CTAs,
and focus rings, and nothing else colored. Page structure is Tailwind utilities
in the ERB templates; a small component layer in `site.css` covers the two
things utilities can't reach — DOM the demo JS builds at runtime (cards, chips,
notes, grid cells; every one of those classes is load-bearing for the JS and
the e2e, so they are styled, never renamed) and the docs' rendered markdown.

Code blocks are highlighted server-side by Commonmarker's built-in syntect
highlighter (`DocPage::CODE_THEME`), the same pipeline for docs pages and the
home page's snippets, so there is no client-side highlighting and no extra gem.

Two lessons are baked into the stylesheet's comments: no `scroll-smooth`
(animated scrolling makes any automated scroll-then-click race the animation —
it broke the e2e, and the same race hits real users of assistive tech), and a
global `scroll-margin-top` so nothing scrolls under the sticky header.

## What this app is not

It is a demo of yrby, not a template for a production collaborative app. The
things it does differently from one:

- No authentication. Rooms are public and anonymous, and anyone with the link
  can edit.
- No accounts and no ownership. Any document is writable by anyone holding its
  link, and the sweeper deletes it after a day untouched.
- One process, one box. The throttle accounting assumes it, and the demo does
  not need more.

`examples/actioncable-demo` in this repo is the other end: Postgres, AnyCable,
multi-process, and the full test and load suites.
