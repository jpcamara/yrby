# yrby site

The documentation and live-demo site for [yrby](https://github.com/jpcamara/yrby).
It's a Rails app, and its demo rooms use the same storage the docs describe:
`Y::Document.load_state` and `Y::Document.append`, the gem's own models, on a
SQLite file. There's no Postgres or Redis, and the server keeps no document
state in process memory between messages.

WebSockets go through [anycable-thruster](https://github.com/anycable/thruster),
which is Thruster with anycable-go embedded in the proxy. `thrust bin/serve`
starts the proxy, the AnyCable server, and Falcon with one command. The Go
server holds every socket and calls Rails over HTTP RPC, so Ruby only ever
handles short requests.

```
site/
├── app/lib/           room caps, rate limiters, the demo list, the docs model
├── app/channels/      DocumentChannel, NoteChannel, the guards, and the connection
├── config/limits.rb   every rate, size, and count limit, with the reasoning for each
├── db/                the vendored yrby:tables migration and the schema
├── docs/              the documentation pages, as markdown
├── frontend/          bun build for the demo bundles, plus the e2e scripts
└── test/              caps, throttles, sweeper, controllers
```

## The record-backed example

The site uses the published gems and `yrby-client` from npm, the same
packages the docs tell you to install.

To build the frontend, run `bun install --frozen-lockfile` and `bun run build`
from `site/frontend`.

`/examples/document` uses a single `ExampleDocument` record. Its migration
creates it, and `db/seeds.rb` creates it on a fresh database (running the seeds
again is safe). Reading the page anonymously creates no records. The view
renders `collaborative_document_tag`. CodeMirror mounts on `yrby:synced` and is
destroyed when `detail.signal` aborts. The helper markup stays in a template
until the AnyCable consumer and the delegated listener are set up. The read
panel calls `collaborative_document(:body).y_doc.read_text("content")` in Rails.

`RecordChannelGuard` is prepended to the gem's own `Y::DocumentChannel`, and
`RoomGuarded` is included in it. Together they give the channel the same
seats, frame limits, write budget, and awareness rules as the room demos. The
guards go on the gem's class because a guard on an app subclass could be
skipped by a client that subscribes to `Y::DocumentChannel` by name.
lexxy-realtime's channel and `NoteChannel` extend `Y::DocumentChannel`, so
they get the same guards. An `authorize_document` block on `Y::DocumentChannel`
only lets this example's body through
(`config/initializers/record_channels.rb`). These limits are this site's
policy for an anonymous demo. Your app doesn't need them to use yrby.

The idle-document sweeper clears this example's CRDT content like any other
room, and the record itself stays. Every visitor shares this one document. The
other demos give each visitor a separate room URL.

`bin/rails test` runs the docs' scratchpad hooks with out-of-order updates, the
Ruby read example that goes through storage, and the example's controller and
channel policy. `PORT=3888 node document_e2e.mjs`, run from `frontend` after
`./boot_server.sh`, opens two agent-browser windows and checks editing, the
Ruby read-back, a clean remount, and delivery of pending edits after the element
is removed from the page. `site_e2e.mjs` tests the other editor and shape demos.


## Running it

The app pins Ruby 3.4.5 in `.ruby-version`, so rbenv and asdf pick it up when
you run commands inside this directory.

```bash
bundle install
cd frontend && bun install && bun run build && cd ..
PORT=3000 frontend/boot_server.sh
```

`boot_server.sh` sets the AnyCable environment, runs `thrust bin/serve`, waits
until both the pages and the cable respond, and writes a pidfile. thrust sets
`PORT` to its `TARGET_PORT` before it starts its command, and `bin/serve` turns
that into Falcon's `--bind`. If you run Falcon by itself you get the pages but
no WebSocket. Rails' own `/cable` mount is turned off, because the Go server in
the proxy handles the cable.

On macOS, export `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` before you boot by
hand. Falcon forks its worker from the controller process, and macOS won't
allow that fork after certain Objective-C runtime setup. Without the variable
the worker dies at boot and every request gets a connection reset.
`boot_server.sh` sets it for you.

Tests:

```bash
bin/rails test
cd frontend && bun run lint
```

The two-browser end-to-end test runs against the same stack as production:
the proxy, embedded AnyCable, and Falcon.

```bash
cd frontend
PORT=3888 SERVER_PIDFILE=/tmp/site.pid ./boot_server.sh
PORT=3888 node site_e2e.mjs
kill "$(cat /tmp/site.pid)"
```

None of this needs Postgres or Redis, tests included. The database is a SQLite
file under `storage/`, created by `db:prepare`, which `boot_server.sh` runs.

## Document storage

`DocumentChannel` uses the hooks from the docs as written:

```ruby
on_load { |key| Y::Document.load_state(key) }
on_change { |key, update| Y::Document.append(key, update) }
```

The site's size cap is checked before the update reaches `on_change`.
`RoomGuarded` reserves the bytes through `Rooms#reserve_write` (see
[Measuring room size](#measuring-room-size)).

`Y::Document` and `Y::DocumentUpdate` come with the yrby-rails gem. The
vendored `yrby:tables` migration in `db/migrate` creates their tables in
SQLite: one file under `storage/`, on a mounted volume in production. Loads
don't lose anything. An update that arrives before an update it depends on is
kept as a pending struct and applied once the missing update shows up.
Compaction folds the tail every 64 rows, and it sets gapped rows aside without
dropping them. The server keeps no document state in memory between messages,
so an idle room costs a few rows on disk and almost no RAM.

The channel rebuilds state from the database on each message, so the number of
rooms is limited by disk space and not by what one Ruby process can hold. It
also means the [Storage](/docs/storage) page describes the code running here.

The site's own code around the hooks is in `app/lib/rooms.rb` (seats, caps, and
a cached size check) and `app/lib/room_sweeper.rb` (deleting idle rooms).

Rooms are temporary on purpose. Documents survive restarts and deploys because
they're rows on a volume. The sweeper deletes rooms nobody has touched for 24
hours. These are public, anonymous, unmoderated documents, and the site tells
visitors they're temporary. That's why the TTL exists, even though memory isn't
a constraint.

## The stack

```
browser ──ws──► thrust (Go) ──HTTP RPC──► Falcon ──► DocumentChannel ──► Y::Document
        ──http─►    │                                                    (SQLite)
                    └──► Falcon (pages)
```

`thrust bin/serve` is one command in one container. Inside it, anycable-go
handles `/cable` and proxies everything else to Falcon. For connect, subscribe,
and every message, it calls Rails at `/_anycable`, the HTTP RPC endpoint
AnyCable mounts in the app. Rails sends broadcasts back to the Go server over
localhost. There's one node, so neither direction needs Redis.

This split keeps the site cheap to run. Ruby holds nothing between messages. A
client that's connected but idle is a goroutine in Go, with no thread or object
in Ruby. Awareness frames do reach Ruby on this site, because the demo sends
them through the guarded `send` path (see
[Presence goes through send](#presence-goes-through-send)).

### Why Falcon

The Ruby side only serves short HTTP requests: page renders and RPC calls.
Falcon's fiber reactor suits that work. There's no thread pool to size, and a
request that waits on IO lets other requests run. yrby's CI also tests the
native extension under Falcon. The demo app's e2e suite boots under both Puma
and Falcon, and this site runs the Falcon setup in production, with the
extension inside the fiber scheduler.

### Why one process by default

Falcon runs with `--count 1` unless you set otherwise. With SQLite behind the
hooks, the documents don't need a single process. The store is shared on disk,
broadcasts already go through the embedded Go server, and SQLite in WAL mode
handles several processes on one box.

The throttle bookkeeping is what assumes one process. The seats and size cache
in `Rooms`, `ConnectionLimiter`, `ConnectionGuard`, `WriteBudget`, and
Rack::Attack's counters all live in process memory. With N workers, each one
enforces its own copy, so the caps can get up to N times looser. The site runs
one process by default, so each limit is counted in one place. A demo site
doesn't need more.

`FALCON_COUNT` (or `WEB_CONCURRENCY`) turns on forked workers. Setting
`FALCON_THREADS` as well switches Falcon to its hybrid container, with forks
times threads. Use these for load tests, or for deployments where approximate
caps are acceptable. To scale out with exact caps, move those counters to a
shared cache, and probably move the database to Postgres.

Sockets end in Go, so Rails builds a fresh channel instance for every command,
and instance variables don't survive between commands. Anything the channel
needs to remember, such as whether it holds a seat in the room or has already
sent the full-room notice, is declared with `state_attr_accessor` and sent back
and forth as JSON in the RPC exchange. The channel passes the key to
`sync_receive` on every call for the same reason. This is the AnyCable setup
yrby's README describes. The per-connection frame bucket and subscription
budget are different: they live in `ConnectionGuard`, in process memory.

### Concurrency

Under Falcon, RPC requests run as fibers, mostly on one thread. They switch at
IO and scheduler yields, not preemptively. SQLite handles concurrent document
writes, in WAL mode with Rails' busy timeout.

The site's own bookkeeping (the seats and size cache in `Rooms`, and
`ConnectionLimiter`) still takes explicit locks. A fiber can yield wherever IO
happens, the reactor can serve requests concurrently, the sweeper runs on a real
`Thread`, and an uncontended mutex is cheap. Database reads happen outside the
locks, so a fiber never waits on SQLite while it holds one. The code is also
correct under preemptive threads, and the test suite runs it that way.

## Throttling

On a public collaborative demo, anyone can open a socket and send frames
without an account. Eight layers limit what one visitor can do. Every number
is in `config/limits.rb` with the reasoning next to it. The table below
summarizes them.

| Layer | Limit | Value | Why |
|---|---|---|---|
| 0. anycable-go | bytes per WebSocket message | 192 KiB | Go refuses an oversized frame at the socket, so it never becomes an RPC call. Set with `ANYCABLE_MAX_MESSAGE_SIZE`. This limit covers the whole *encoded* message, so it's higher than the 128 KiB *decoded* cap below (base64 adds about a third, plus the JSON envelope). |
| 0. anycable-go | concurrent sockets, process-wide | 500 | The hard ceiling, enforced by the process that holds the sockets. Set with `ANYCABLE_MAX_CONN`. The Ruby caps below add a per-IP limit and a soft cap in front of it. |
| 1. Rack::Attack | page requests per IP | 60 / minute | A reader loads a page every few seconds. Static files and `/up` don't count. Public requests to `/_anycable` are blocked, and the Go server's authenticated RPC calls skip the throttle. |
| 2. Connection | concurrent sockets per IP | 8 | Opening a second window is the point of the demo, and a visitor may open one per page. More than that is a script. The count uses the real client IP (it accounts for trusted proxies), and each slot has a token, so a disconnect frees its own slot and not the oldest one. |
| 2. Connection guard | subscriptions per socket | 20 | Each subscription takes a room seat and can create a document. This limits how many rooms one socket can reach (160 per IP, with the per-IP cap). |
| 2. Connection guard | subscribe commands per socket | 5 / s, burst 20 | Stops a socket from cycling through rooms with repeated subscribe and unsubscribe. |
| 3. Token bucket | frames per second, per socket | 40, burst 120 | Typing plus awareness at pointer-event rate stays well under this. There's one bucket **per connection**, so re-subscribing doesn't reset the burst, and extra subscriptions don't add rate. |
| 3. Token bucket | dropped frames before the socket closes | 200 | Short runs of dropped frames are normal during a fast drag. A client that keeps going past 200 isn't a person. |
| 3. Write budget | document writes per second, process-wide | 400, burst 800 | A shared limit in front of single-writer SQLite. Past it, the server drops document frames, so a flood slows writes down without locking up the database with `SQLITE_BUSY`. Awareness frames don't count. |
| 4. Frame size | bytes per frame | 128 KiB | yrby's default is 8 MiB, sized for a real app's initial `SyncStep2`. Demo documents are tiny. This is the *decoded* cap. See the Go message cap in layer 0. |
| 5. Document size | bytes per room | 512 KiB | About ten times a realistic demo document. The server reserves the bytes before it accepts an update, so the update that would cross the cap is the one refused. At the cap the room becomes read-only and the page says so. |
| 6. Room caps | peers per room | 12 | More than a dozen carets is unreadable, and each peer is another target for every broadcast. One connection can hold at most one seat in a room. |
| 6. Room caps | documents on disk | 2000 | 2000 x 512 KiB keeps the database file to about 1 GB of disk. The count includes **reservations**: rooms with a seated visitor that haven't been written yet. That way a flood of `subscribe`s can't get past the cap before their documents exist. |
| 7. Eviction | idle time before a room is deleted | 24 hours | Rooms are public and anonymous, and the site says they're temporary. A link shared in the morning still works after dinner. The sweeper claims a room under a lock before deleting it, so it can't delete a room that someone is joining or writing to. |

Rack::Attack has no throttle for cable handshakes. `/cable` never passes
through Rack, because the Go server answers it in the proxy, so a limit there
would count nothing. The per-IP connection cap limits handshakes instead, and
it runs in Ruby on the Connect RPC. Public requests to the RPC endpoint
(`/_anycable`) are blocked, because an outside client doesn't have the Go
server's bearer token. The Go server's authenticated calls skip the throttle,
since every message on the cable goes through them.

The sections below cover the limits that need more explanation than a table
row.

### Reservations and per-connection buckets

A room has no database row until its first write, but a subscription takes a
seat as soon as it joins. Without extra accounting, a burst of `subscribe`s for
different keys would all be admitted (there are no rows yet) and then each
create a document, going past the room cap. So the first seat in a brand-new
room counts as a *reservation* against the cap until the room is written or its
last occupant leaves.

The frame bucket and the subscribe budget belong to the connection for a
similar reason. A bucket per subscription would reset on every subscribe, and a
socket with several subscriptions would get several buckets' worth of rate. One
bucket per socket avoids both problems.

### The RPC endpoint

`/_anycable` checks callers for a bearer token derived from `ANYCABLE_SECRET`.
The embedded Go server calls it directly over loopback. thrust's public proxy
would forward that path to Falcon like any other, since both reach Falcon on
the same port. So Rack::Attack blocks it at the edge. A request without the
bearer gets a 404, and the Go server's authenticated calls go through.

In production, set `ANYCABLE_SECRET` to a strong value. With the committed
development default, anyone could compute the bearer and send RPC calls
directly, skipping the socket and every limit. The app won't boot in
production if the secret is unset, the default, or too short.

### Rate limits and frame validation

yrby already checks that every frame is a single well-formed protocol message,
and drops anything malformed, truncated, multi-message, or oversized. That
doesn't limit volume. A client sending valid updates as fast as it can is still
a denial of service, so the channel's `receive` runs the token bucket before it
calls `sync_receive`.

### Full rooms

The obvious way to enforce a document size cap is to raise from `on_change`.
That doesn't work here. When `on_change` raises, the update is rejected without
an ack, and the client retransmits an unacked update forever because the
protocol has no negative ack.

So the channel checks the cap before it hands the frame to yrby. If the room is
full, it drops the frame and transmits a one-time
`{ "notice": "document_full" }`. The page shows that as a prompt to open a new
room. Awareness frames still go through in a full room, so presence keeps
working.

### Measuring room size

The true size of a room is its snapshot bytes plus its tail bytes, which takes
a SUM over rows. That's too expensive to run on every frame. Polling it would
leave a gap where a flood could append megabytes between polls.

So `Rooms` keeps a cached size per room. `Rooms#reserve_write` adds each
update's bytes to the cache when it admits the update, which keeps the cap
accurate at any write rate without a query on the hot path. The server re-reads
the database only when a cache entry is older than 30 seconds, to pick up
compaction. Compaction only shrinks the true size, so between refreshes the
cache can only overestimate, which is the safe direction for a cap. At worst, a
room that was just compacted stays read-only for a few extra seconds.

### Idle eviction

Most visitors create a room and leave within a minute. Without the sweeper
(`app/lib/room_sweeper.rb`, one thread, a sweep every five minutes), normal use
would reach the 2000-document cap. A room is stale when it has had no write
within the TTL and nobody is in it. The sweeper never evicts an occupied room.

The sweeper can't just delete a snapshot of stale rooms. A join or an append
could happen in between, and it would delete a document out from under an
active session. So the stale set is only a list of candidates. `Rooms` then
checks seats and marks, in one locked step, the candidates that have no
occupant and no reservation. After that, a join is refused and a write can't
reopen them. The sweeper reads the database again and deletes only the rooms
that are still stale.

### Leaked connections

The same sweep cleans up leaked connections. The Disconnect RPC frees a seat
and a connection slot, but that RPC might never arrive (a dropped socket, a
network partition). A leaked seat is worse than a leaked slot. It keeps a room
occupied, so the sweeper won't evict it, and it holds a peer slot forever.

So the sweep cleans up a connection based on when the server last heard from it.
`ConnectionGuard` records the last frame the server saw from each connection.
When a connection has been silent longer than the TTL (an hour), the sweep
releases its room seats and its connection slot (by the slot's token). Releasing
the seats frees the peer slots and lets an abandoned room be evicted.

Any frame resets the clock, whether it's a document update or awareness. That's
one reason awareness goes through `send` (see below). yrby-client re-sends
awareness on a heartbeat, so a reader with an idle tab open stays connected.
If the sweep cleans up a connection that's still open, the caps get looser for
a while, and nobody is turned away. `ANYCABLE_MAX_CONN` on the Go process is the hard ceiling on real
sockets.

### Presence goes through send

Under AnyCable, yrby-client can send presence as a *whisper*, which anycable-go
relays from client to client without reaching Ruby. That works well in an
authenticated app where peers trust each other.

This demo turns whispers off. The demo channels remove the whisper option, so
anycable-go never enables whispers on a stream. The page hides `whisper` from
the provider, so awareness goes out over `send`. The rooms are public and
anonymous. With whispers on, one peer could send a raw `{ update: … }` document
frame straight to the others, skipping the token bucket, the size caps,
persistence, and every check the receive path runs.

Over `send`, every frame goes through the guard, awareness included. Awareness
is cheap there (a frame-bucket token, no document write), and it's how the sweep
above can tell a connection is alive. Whispers are still fully supported
in the published `yrby-client` and `yrby-rails`. Only this anonymous demo turns
them off.

### No uploads

The site accepts no files. A public, anonymous write surface with a file
endpoint is a free file host. The throttles above all limit what a stranger can
use up, and this app has no reason to hand out disk or object storage at all.
So the app has no upload path to configure:

- Active Storage isn't loaded. The app requires only the Rails frameworks it
  needs, including Active Record for document storage. The activestorage and
  actiontext gems are in the bundle, because lexxy-realtime depends on the
  `rails` meta-gem, but nothing requires them, so no upload engine or route
  is mounted.
- There are no upload routes, no direct-upload endpoints, and no multipart
  handling.
- The Tiptap demo uses StarterKit only. It has no Image extension, so the
  editor's schema has no node a file could become. The Lexxy demo mounts its
  editor with `attachments="false"`, which removes Lexxy's upload buttons and
  its file paste and drop handlers. Lexxy's upload code imports
  `@rails/activestorage`, which the app doesn't install, and `build.mjs` marks
  that import as external.
- `frontend/src/room.js` refuses files before any editor sees them. On every
  demo page it cancels `paste`, `drop`, and `dragover` events that carry files,
  in the capture phase on `document`. The Tiptap editor also returns "handled"
  from its own `handlePaste` and `handleDrop` for those events. Text pastes
  work normally.

### Process-local counters

Rack::Attack's cache is an `ActiveSupport::Cache::MemoryStore`, so its counters
live in this process like the rest of the throttle bookkeeping. That works
because the site runs one process. With several processes, all of this would
need a shared cache, and most of it would be better handled at the CDN.

## Caching

Docs pages are server-rendered markdown with nothing specific to a visitor, so
the app sends them with

```
cache-control: public, max-age=3600, stale-while-revalidate=86400
```

A CDN serves them for an hour, then keeps serving the stale copy while it
refreshes in the background. A deploy doesn't send a burst of misses to the one
process, and readers don't notice a restart. Demo pages are `no-store`, because
each one belongs to a room and the state is in the room.

## Hosting

The repo has setups for three hosts. Each one works on its own, so pick one.

### Fly.io

`fly.toml` runs one `shared-cpu-1x` machine with 1 GB of RAM and a 1 GB volume
for the database. It sets `auto_stop_machines = "suspend"`,
`auto_start_machines = true`, and `min_machines_running = 0`. The machine
suspends when nobody is using it and starts on the next request, which suits a
demo that's idle most of the time. The documents are in SQLite on the volume,
so a stopped machine loses nothing. A returning visitor's link still works, and
rooms expire on the sweeper's schedule, whether or not the machine stopped. It
costs roughly **$2-4/month** at low traffic.

Fly is the option to use if you don't want to run a server yourself.

### Kamal on a VPS

`config/deploy.yml` deploys one container to one host. kamal-proxy terminates
TLS, and the database is on a named Docker volume. A Hetzner CX22 (2 vCPU,
4 GB) costs about **€4/month** flat and holds far more concurrent connections
than the Fly machine above. You own the box and its updates. The 4 GB and the
steady disk suit a database-backed app, and with no scale-to-zero there's no
cold start when someone opens a demo.

### Hatchbox

The site also deploys to Hatchbox, using the two scripts in `.hatchbox/` at the
repo root.

Hatchbox runs `.hatchbox/pre-build` from the release directory before the
build. It writes a `.tool-versions` file at the repo root and in `site/`, with
the newest Ruby and Bun that Hatchbox installed, and sets `site/.ruby-version`
to that Ruby. Hatchbox runs some Bundler commands from the repo root, where the
Gemfile is the gem's, so the script points Bundler at `site/Gemfile`. It also
replaces `site/storage` with a symlink to a shared directory, so the SQLite
database is kept across deploys.

`.hatchbox/build` then installs the gems into a shared bundle path (deployment
mode, without the development and test groups), installs and builds the
frontend with bun, and runs `bin/rails db:prepare`.

### Cloudflare in front

Cloudflare's free tier is worth putting in front of any of these, for two
reasons. Docs pages become CDN hits that never reach the app. And the free plan
absorbs volumetric attacks that would otherwise hit one small machine.
WebSockets pass through on the free plan, so the demos keep working. Leave the
cable path uncached. It already is, because those responses are `no-store`.

### Secrets and origins

Kamal reads secrets from `.kamal/secrets`, which is gitignored. Copy the
committed template and fill it in. You can also have each line pull from a
password manager so the secrets never get written to disk:

```bash
cp .kamal/secrets.example .kamal/secrets
# SECRET_KEY_BASE=$(openssl rand -hex 64)    # Rails signing key
# ANYCABLE_SECRET=$(openssl rand -hex 32)    # configures both halves of the cable
```

`config/deploy.yml` lists both under `env.secret`, so they reach the container
as environment variables and never appear in the committed YAML. On Fly, set
them with `fly secrets set …`. The image sets the SQLite volume to `chmod 700`,
so only the app user can read the database and its room content.

**Production requires both `ANYCABLE_SECRET` and `ALLOWED_ORIGINS`, and won't
boot without them.** `ANYCABLE_SECRET` must be at least 32 characters and can't
be the committed development default. The `/_anycable` RPC endpoint
authenticates callers with a bearer derived from it. With a weak or default
secret, anyone could forge RPC calls and skip the socket and every limit.

`ALLOWED_ORIGINS` must list the site's own origins. Without it, Rails turns off
the cable's forgery protection, and any page on the internet could open a socket
to the cable from a visitor's browser (cross-site WebSocket hijacking).
`config/initializers/production_boot_checks.rb` enforces both checks.
Development, test, and the local e2e run without them.

Set `ALLOWED_ORIGINS` in the deploy environment as comma-separated full
origins, such as `https://yrby.dev`, or `http://192.168.1.10:3000` for a
plain-http LAN box. That one value configures both halves of the cable:

1. The entrypoint strips the scheme to build `ANYCABLE_ALLOWED_ORIGINS` for the
   embedded anycable-go, which returns 403 for a handshake from any other
   origin.
2. Rails checks the Origin again on the Connect RPC. That's why
   `ANYCABLE_HEADERS` forwards `origin`. anycable-rails treats a *missing*
   Origin as allowed, so the Rails check only works if the header reaches the
   RPC.

Behind Cloudflare, the throttles also need the visitor's real IP.
`trusted_proxies` lists Cloudflare's ranges, loopback, and the
container-internal ranges, and leaves out `192.168.0.0/16`. The cable's per-IP
cap works out the client IP from that same list and doesn't use
`request.remote_ip`. On the RPC path the RemoteIp middleware never runs, and
`remote_ip` would fall back to a rule that accepts a forged `X-Forwarded-For`
from a client connecting straight to the edge. The site's rule only uses a
forwarded address when the hop that sent it is on the trusted list.

Set `CANONICAL_HOST` in the same deploy environment to the site's real origin,
for example `https://yrby.dev`. The app uses it for canonical tags, Open Graph
and Twitter URLs, the sitemap, JSON-LD, and llms.txt. The app doesn't take it
from the request, because the request host changes behind Cloudflare or on a
plain-http LAN box. **It defaults to the `yrby.example.com` placeholder, and
the SEO tags are wrong until you set it.**

Each setup runs the app on one machine. The database volume attaches to one
box, and the throttle counters assume one process. That's fine for a demo
site, and moving to a bigger box is a one-line change.

The Dockerfile and `boot_server.sh` also set `MAX_REQUEST_BODY=65536` for
thrust, a cap on request bodies at the proxy. Every public route is a GET, so
64 KB is plenty. The cap doesn't affect AnyCable. The embedded Go server
connects to Falcon's port directly for RPC and receives broadcasts on its own
listener, so neither path goes through thrust's public handler. In thruster's
source (`internal/service.go`), the body cap only wraps the inbound proxy.

## Capacity

The number that matters for a demo site is concurrent WebSocket connections,
and the app caps it at 500 (`MAX_CONNECTIONS`).

anycable-go holds each socket as a goroutine plus its read and write buffers,
around 10 KB, so 500 sockets take 5-10 MB. Ruby holds nothing per connection
between messages. Rails builds the channel object for one command and then
discards it, so an idle client costs Rails nothing. A document uses RAM only
while it's being loaded or applied. Documents live in SQLite, and the room caps
(2000 documents at 512 KiB) keep the database file to about 1 GB of disk. What
stays in memory is Rails plus the yrby native extension, 150-200 MB. The rest
of a 1 GB machine is headroom for CRDT work in progress. Applying an update
allocates memory, and `on_load` replays a room's snapshot and tail into a fresh
`Y::Doc` on each handshake.

So memory doesn't run out at 500. The cap is set low so that under heavy load
the server refuses new connections before the machine starts swapping. On
memory alone, the Go side could hold several thousand sockets.

CPU is the real limit, and Ruby is what uses it. Every document frame is an RPC
call into the Falcon reactor plus a native CRDT apply. yrby releases the GVL
for that work, so the fiber scheduler keeps serving while the native code runs.
Still, one shared vCPU can't handle 500 people typing at once. SQLite adds a
write per update and a read per load on the same box, which is negligible at
demo scale with WAL.

Presence also costs Ruby time on this site. The demo sends awareness through the
guarded `send` path, so each awareness frame is an RPC call and a relay
broadcast. It doesn't write to SQLite or apply to a document, but it isn't free
the way a client-to-client whisper is. That's the cost of not giving anonymous
peers an unguarded relay. The frame bucket limits it per connection. An
authenticated app that trusts its peers can put presence back on whispers and
skip Ruby.

Realistically, the site can comfortably hold several hundred connected clients
with a few dozen editing at once, which is what a demo site sees.

I haven't load-tested this app at those numbers. The estimate comes from
per-connection costs, not a measurement, and the split between what Go holds and
what Ruby does is what I'd measure first. `frontend/loadtest_site.mjs` drives
raw Action Cable clients against `DocumentChannel` and reports connections,
throughput, and latency. The demo app in `examples/actioncable-demo` has
`loadtest.mjs` and `stress.mjs`.

## Docs pages

`app/lib/doc_page.rb` renders `docs/*.md` on each request with Commonmarker
(GFM). `DocPage::PAGES` sets the nav order and the README section each page
comes from. The page title is the file's first `#` heading, so it always
matches the content.

The repo README is the main reference. These pages copy it, and copies drift,
so every page says so and links back to its README section. When the README
changes, update the matching page here.

The in-page table of contents reads its anchors from the heading ids in the
rendered HTML. `DocPage#sections` parses the `id` attributes Commonmarker
generated, without re-slugifying the markdown, so the contents links always
match the ids they point at.

## Discoverability

The files crawlers and LLMs look for are rendered from the same page lists as
the site, so they stay in sync:

- **`robots.txt`, `sitemap.xml`, `llms.txt`, `llms-full.txt`.** `MetaController`
  serves these from `DocPage` and `Demos`. They aren't committed static files,
  so the URL set and the canonical host stay correct as pages are added.
  `robots.txt` lets crawlers index the docs and the `/demos` index, and
  disallows each `/demos/:slug` prefix. A bare demo URL creates a new room and
  redirects, so a crawler that followed those links would generate unlimited
  URLs. Demo room pages are also `noindex, nofollow`, with `/demos` as their
  canonical URL.
- **Markdown for agents.** Every docs page responds to `Accept: text/markdown`
  and to a `.md` suffix (`/docs/storage.md`) with its raw markdown plus a short
  metadata block at the top. `llms.txt` points at the `.md` URLs, and
  `llms-full.txt` concatenates them.
- **Canonical, Open Graph, Twitter, and JSON-LD.** These are in the layout's
  head, driven by `content_for :title`, `:description`, and `:canonical`. The
  home page has a `SoftwareSourceCode` block, and docs pages have `TechArticle`
  and `BreadcrumbList`. The JSON-LD is inline `application/ld+json`. The strict
  `script-src` CSP doesn't apply to it, because browsers never execute it.
- **`public/og.png`.** A 1200×630 social card in the site's light design. Its
  source is `frontend/og/card.html`. To change it, edit that page and run
  `bun run build:og` from `frontend/`, which renders it with agent-browser.

## Demos

There are six demo pages, picked to cover different Yjs shapes:

| Page | Shape | What it shows |
|---|---|---|
| Lexxy | `Y.XmlText` | Lexxy on the published lexxy-realtime stack: the `<yrby-document>` wrapper, a channel built on the gem's, a record-backed document, and the server rendering `note.body` with `Y::Lexxy` |
| Tiptap | `Y.XmlFragment` | The same shape through Tiptap's own Collaboration extension |
| Spreadsheet | `Y.Array` of row `Y.Map`s, cells nested | Cell-level merges, with sorting kept out of the document |
| Whiteboard | `Y.Map` | Records in a map, the way canvas tools store shapes |
| Kanban | `Y.Array` | A move is one `map.set`, so concurrent moves never conflict |
| Code | `Y.Text` | CodeMirror 6 with remote cursors and selections |

### The Lexxy demo

The Lexxy page uses the published `lexxy-realtime` gem and npm package (both
0.8.0) the way a real app would. These are the parts that differ for public,
anonymous rooms, and why:

- **The record.** Each room is a `Note`. `NoteChannel` creates it on
  subscribe, never on the page GET. `has_collaborative_rich_text :body` comes
  from the gem's Collaborative concern, which checks whether Action Text is
  loaded. This app doesn't have Action Text, so the concern uses its
  plain-column path. After each update, the channel renders the document with
  `Y::Lexxy` and writes the HTML directly into `notes.body`. The page's
  "Stored HTML" panel reads that column back through a GET-only JSON endpoint.
  The server rendered that markup, with no browser involved. The `nodes:` rules
  on the macro render attachment nodes as nothing, because the site accepts no
  uploads.
- **The grant.** The gem's form helper signs a GlobalID for a saved record,
  and this page can't create a `Note` on a GET. A GET is anonymous and has no
  cap, so a crawler could otherwise create rows without limit. So the page
  signs the room id for the `body` field (`Note.room_token`) and renders it as
  the `grant` of a `<yrby-document name="body" channel="NoteChannel">`.
- **The channel.** `NoteChannel` extends the gem's
  `LexxyRealtime::DocumentChannel` and overrides three things. `locate_record`
  finds the room's `Note` from the room token. `subscribed` creates the `Note`
  first, within the room budget. Its `authorize_document` block allows
  everyone, because the rooms are public. A token for a different field
  doesn't verify, and the parent still rejects a field that isn't declared
  with `has_collaborative_rich_text`. The rest is the gem's channel: storage,
  acknowledgments, and rendering `note.body`. The seats and throttles come
  from `RecordChannelGuard` and `RoomGuarded` on `Y::DocumentChannel`, like the
  record-backed example's.
- **The markup.** `collaborative_rich_textarea` needs a saved record and
  builds the editor with Lexxy's Action Text form helpers, which this app
  doesn't load. So the page renders the helper's markup directly: a
  `<yrby-document>` around the `<lexxy-editor>`, with a
  `<lexxy-collaboration doc-id>` inside it. `frontend/src/lexxy.js` imports
  `lexxy-realtime`, which registers both elements, and passes `setConsumer` a
  function that returns the same AnyCable consumer as the other demos, with
  the room bar, the full-room notice, and whispers hidden. On each
  `yrby:synced` it wires the presence chips, the status line, and the stored
  HTML panel to the session's provider and Yjs document.
- **One copy of `lexical`.** `build.mjs` pins `lexical` and `@lexical/yjs` to a
  single copy each, alongside the yjs packages. Two copies of `lexical` break
  node-class identity, the same way two copies of yjs break constructor checks.
- **Loading the gem without its engine.** The gem is `require: false`. Its
  engine loads the Lexxy gem's engine, which sets up Action Text helpers in
  `to_prepare` and can't boot without Action Text. `config/lexxy_realtime.rb`
  requires `lexxy_realtime/collaborative`, which works on its own, and defines
  the two module methods the concern and the channel call.
  `config/application.rb` adds the gem's `app/channels` to the load paths so
  `LexxyRealtime::DocumentChannel` loads.

The demos are ports of the pages in
[`examples/actioncable-demo`](../examples/actioncable-demo). The provider
setup, presence chips, status line, and room bar live in
`frontend/src/room.js`, so each demo file holds only its Yjs binding.

Each visitor gets a fresh room: `/demos/tiptap` creates one and redirects. The
demo nav keeps the room id, so switching pages keeps you in the same room with
a different document key.

`frontend/src/room.js` also wraps the Action Cable consumer so the page can
read the server's `{ notice: ... }` messages. `yrby-client`'s provider ignores
messages it doesn't recognize. The mixin it builds reaches the provider through
a closure and doesn't use `this`, so wrapping its `received` handler is safe.

### Building the bundles and the stylesheet

```bash
cd frontend && bun run build     # JS bundles, fonts, and CSS
bun run watch                    # rebuild bundles on change
bun run watch:css                # rebuild the stylesheet on change
```

Each demo has an entry in `build.mjs` and builds to `public/<slug>.js`, which
the demo page loads by slug. The home page replay (`hero.js`) and the
record-backed example (`document.js`) build the same way.

The build pins `yjs`, `y-protocols`, and `lib0` (and `lexical` and
`@lexical/yjs` for the Lexxy page) to one path each. Two copies of `yjs` in one
bundle is a hard bug to track down. The provider and the editor binding end up
on different `Y.Doc` internals, y-prosemirror throws "Method unimplemented"
when it applies remote updates, and nothing about the symptom points at module
resolution. The comment at the top of `build.mjs` has the details.

## Frontend styling

Tailwind v4 builds with the same bun toolchain as the bundles.
`bun run build:css` compiles `frontend/css/site.css` to `public/site.css`
(purged, a few KB gzipped), and the app serves it as a plain static file.
There's no asset pipeline. Everything the browser loads is a file bun built.

The design looks like a shared manuscript: a newsprint page, documents on white
sheets, ink-colored text, and one red accent for links, buttons, and focus
rings. Headings use Newsreader, body text uses IBM Plex Sans, and code uses IBM
Plex Mono. `bun run build:fonts` copies the font files into `public/fonts`,
because the CSP doesn't allow loading anything from other origins. The
templates use Tailwind's zinc and rose classes, and the theme in `site.css`
remaps those scales onto the paper palette.

Page structure is Tailwind utilities in the ERB templates. A small component
layer in `site.css` covers the two things utilities can't reach: DOM that the
demo JS builds at runtime (cards, chips, notes, grid cells), and the docs'
rendered markdown. The demo bundles and the e2e scripts select on those runtime
classes, so they get styled and never renamed.

Code blocks are highlighted on the server by Commonmarker's built-in syntect
highlighter, with the InspiredGitHub theme (`DocPage::CODE_THEME`). Docs pages
and the home page's snippets use the same pipeline, so there's no client-side
highlighting and no extra gem.

The stylesheet's comments explain two choices. It doesn't use `scroll-smooth`,
because animated scrolling makes any automated scroll-then-click race the
animation. That broke the e2e, and keyboard and assistive-tech users hit the
same race. It also sets a global `scroll-margin-top`, so an element scrolled
into view doesn't end up under the sticky header.

## How this differs from a production app

This is a demo of yrby. It isn't a template for a production collaborative app,
and it differs from one in a few ways:

- No authentication. Rooms are public and anonymous, and anyone with the link
  can edit.
- No accounts or ownership. Anyone with a document's link can write to it, and
  the sweeper deletes it after a day without changes.
- One process on one box. The throttle accounting assumes it, and the demo
  doesn't need more.

`examples/actioncable-demo` in this repo covers a production setup: Postgres,
AnyCable, multiple processes, and the full test and load suites.
