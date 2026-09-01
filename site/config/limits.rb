# frozen_string_literal: true

# Every limit this site enforces, with the reasoning for the number.
#
# The site is a public, anonymous, write-open collaborative demo, which is an
# open door to the process's memory and CPU. Nothing here is a security
# boundary on its own; together they bound how much of one machine a stranger
# can take. The layers are, from outside in:
#
#   0. anycable-go           max WebSocket frame size       (ANYCABLE_MAX_MESSAGE_SIZE)
#   0. anycable-go           max concurrent sockets         (ANYCABLE_MAX_CONN)
#   1. Rack::Attack          per-IP HTTP request rate       (rack_attack.rb)
#   2. ConnectionLimiter     concurrent WebSockets per IP   (connection.rb)
#   2. ConnectionGuard       subscriptions + writes per WS  (connection.rb)
#   3. TokenBucket           frames per second per client   (document_channel.rb)
#   3. write budget          document writes per second     (rooms.rb, process-wide)
#   4. frame size cap        bytes per frame                (document_channel.rb)
#   5. document size cap     bytes per room, total          (rooms.rb)
#   6. room caps             peers per room, rooms on disk  (rooms.rb)
#   7. idle eviction         stale rooms deleted            (room_sweeper.rb)
#   7. leak reaping          silent connections reaped      (connection_guard.rb)
#
# Awareness/presence rides the same guarded `send` path (layer 3 onward) as
# document frames: the demo does not use AnyCable whispers, which would relay
# client-to-client past every layer here (see README "Throttling" and
# RoomGuarded). That is also what lets layer 7's leak reaper see per-connection
# liveness and free a leaked connection's seats and slot.
#
# Layer 0 runs in Go, in the embedded anycable-go inside the thrust proxy, and
# is configured by environment variable rather than from here; the value is
# MAX_FRAME_BYTES below. Layers 2 and 3 run in Ruby, reached over AnyCable's
# HTTP RPC on connect and on every message.
#
# The whole design is written up in README.md ("Throttling").
module Limits
  # --- HTTP (Rack::Attack) ---------------------------------------------------

  # A person reading docs loads a page every few seconds at most, and each page
  # is one HTML request plus static assets (which are not counted). 60/minute
  # leaves a wide margin over human browsing and still caps a scraper at one
  # request per second.
  PAGE_REQUESTS = 60
  PAGE_PERIOD = 60 # seconds

  # There is no cable throttle here. /cable never passes through Rack — the
  # embedded anycable-go answers it in the proxy — so a handshake limit at this
  # layer would count nothing. What bounds handshakes instead is
  # MAX_CONNECTIONS_PER_IP below, enforced in Ruby on the Connect RPC.

  # --- Connections -----------------------------------------------------------

  # "Open a second window" is the whole point of the site, and a curious visitor
  # may open one per demo. Eight is generous for a person and cheap to hold;
  # past that it is a script. The env override exists for load testing, where
  # every connection arrives from one generator IP; production leaves it unset.
  MAX_CONNECTIONS_PER_IP = Integer(ENV.fetch("MAX_CONNECTIONS_PER_IP", 8))

  # --- Subscriptions (per physical connection) -------------------------------
  #
  # One WebSocket can open many channel subscriptions, and every subscription
  # takes a room seat and can create a document. Without a per-connection cap a
  # single socket could subscribe to thousands of distinct rooms and mint a
  # document in each, walking straight past the room cap (which only counts a
  # brand-new key as it is first *seated*). These bound one socket's reach.

  # Concurrent subscriptions one connection may hold. A person opens one room per
  # page and a handful of pages; twenty is generous for that and far below what a
  # script needs to be useful. With the per-IP connection cap (8) this bounds one
  # address to 160 concurrently-held rooms — well under MAX_LIVE_ROOMS.
  MAX_SUBSCRIPTIONS_PER_CONNECTION = Integer(ENV.fetch("MAX_SUBSCRIPTIONS_PER_CONNECTION", 20))

  # Rate limit on `subscribe` commands from one connection, as a token bucket.
  # Opening a page is a single subscribe; even a fast tab-through of every demo
  # is a few per second. The burst absorbs a reconnect storm re-subscribing the
  # tabs a client had open; the sustained rate stops a socket from cycling
  # subscribe/unsubscribe to churn rooms.
  SUBSCRIBES_PER_SECOND = 5
  SUBSCRIBE_BURST = 20

  # Process-wide ceiling. A held socket costs a goroutine and its buffers in
  # anycable-go — on the order of 10 KB, not the ~50 KB an Action Cable
  # connection object costs in Ruby — because Ruby holds nothing between
  # messages. 500 is a deliberately conservative ceiling for a 1 GB machine
  # sitting next to the document store's own; the sockets themselves are not
  # what runs out first. Env override for load testing, as above.
  MAX_CONNECTIONS = Integer(ENV.fetch("MAX_CONNECTIONS", 500))

  # How long a connection may be SILENT before the guard reaps it as leaked,
  # freeing its room seats and its connection slot. `release` normally frees a
  # slot the moment the Disconnect RPC fires; this is the backstop for when that
  # RPC never arrives (a dropped socket, a partition). It is a LIVENESS TTL, not
  # an age: every server-visible frame — a document update or an awareness frame,
  # both of which reach Rails now that the demo routes awareness through `send`
  # rather than a whisper — refreshes the clock. yrby-client re-emits awareness
  # on a heartbeat (~every 15s), well under this hour, so even an idle-but-open
  # reader stays alive to the reaper; only a truly dead connection is reaped. See
  # ConnectionGuard.
  CONNECTION_SLOT_TTL = 60 * 60 # seconds

  # --- Frames ----------------------------------------------------------------

  # Largest single frame accepted, in decoded bytes. yrby's own default is
  # 8 MiB, sized for a large initial SyncStep2 in a real app. Demo documents are
  # tiny, and the whole room is capped at MAX_DOCUMENT_BYTES anyway, so this is
  # cut to a size a legitimate demo edit never approaches. Enforced twice: by
  # anycable-go at the socket (ANYCABLE_MAX_MESSAGE_SIZE) and again by yrby in
  # Ruby. Note the two limits measure different things: Ruby caps the *decoded*
  # update, anycable-go caps the whole *encoded* message (base64 is ~4/3, plus
  # the JSON envelope). The Go limit is therefore set higher — see
  # MAX_MESSAGE_BYTES below — so a legitimately-sized update is not killed at the
  # socket before Ruby's decoded check can run.
  MAX_FRAME_BYTES = 128 * 1024

  # The value ANYCABLE_MAX_MESSAGE_SIZE must carry (bin/serve, Dockerfile,
  # fly.toml). It bounds the whole encoded WebSocket message, so it has to hold
  # a MAX_FRAME_BYTES-decoded update after base64 expansion (4/3) plus the JSON
  # envelope (`{"update":"…","id":N}`). 192 KiB clears
  # MAX_ENCODED_BYTES (~171 KiB) with room for the envelope; smaller and a valid
  # max-size update dies in Go before the RPC. Documented here so the number and
  # its reasoning live with the other frame limits even though Go reads it from
  # the environment.
  MAX_MESSAGE_BYTES = 192 * 1024

  # A process-wide ceiling on document writes per second, shed before they reach
  # SQLite. Every accepted document frame is a single-writer SQLite insert, and
  # the per-subscription and per-connection buckets bound one client, not the
  # sum of all of them — at the intended caps the aggregate still dwarfs what one
  # SQLite file absorbs before SQLITE_BUSY starts starving page requests. This is
  # the aggregate backstop: over it, document frames are dropped (the client
  # keeps the update queued and retries, the same shape as any other dropped
  # frame), so a flood sheds instead of wedging the database. Awareness is never
  # counted here. Generous for real use — a full room typing flat out is a few
  # dozen writes a second — and a hard shelf under abuse.
  DOCUMENT_WRITES_PER_SECOND = 400
  DOCUMENT_WRITE_BURST = 800

  # Token bucket per subscription. Typing produces a handful of frames a second;
  # dragging a whiteboard note or moving a caret produces awareness frames at
  # roughly pointer-event rate. 40/second sustained covers both with room to
  # spare, and the 120 burst absorbs the frames that arrive together at join.
  FRAMES_PER_SECOND = 40
  FRAME_BURST = 120

  # A client over the bucket has its frames dropped. Some of that is normal
  # (a burst of awareness during a fast drag). A client that keeps going past
  # this many dropped frames on one subscription is not a browser being used by
  # a person, so the connection is closed.
  FRAME_DROPS_BEFORE_CLOSE = 200

  # --- Documents and rooms ---------------------------------------------------
  #
  # The store is Y::Document on SQLite, so these caps bound disk and content,
  # not RAM — nothing authoritative is held in process memory between messages.
  # Compaction is the gem's own (Y::Document.compact_every, default 64 tail
  # rows), so there is no compaction constant here.

  # Total bytes of CRDT state held for one room: the compacted snapshot plus the
  # uncompacted tail. A demo document — a page of rich text, a few dozen
  # spreadsheet cells — is tens of kilobytes with its history. 512 KiB is about
  # ten times that. A room at the cap stops accepting document writes and says
  # so on the page; it does not grow until the disk fills.
  MAX_DOCUMENT_BYTES = 512 * 1024

  # Documents on disk at once. 2000 x MAX_DOCUMENT_BYTES is a 1 GB ceiling on
  # the database file, comfortable on any volume. Raised 10x from the in-memory
  # store's 200: rooms now accumulate for a day rather than 20 minutes, and the
  # resource they consume is disk.
  MAX_LIVE_ROOMS = 2000

  # Peers in one room. More than a dozen carets in a demo document is unreadable
  # anyway, and each peer is another fan-out target for every update.
  MAX_PEERS_PER_ROOM = 12

  # How stale the cached per-room size may get before it is re-read from the
  # database. Appends bump the cache immediately (Rooms#note_append), so
  # staleness only ever means over-estimating — the refresh exists to pick up
  # compaction, which shrinks the true size. See Rooms#document_full?.
  SIZE_CACHE_TTL = 30 # seconds

  # A room with no writes and nobody in it for this long is deleted, rows and
  # all. This is a content decision now, not a memory one: rooms are public and
  # anonymous, and "temporary" is a promise the site makes about them. A day
  # means a link shared in the morning still works after dinner, and nothing
  # anyone pastes outlives the day.
  ROOM_IDLE_TTL = 24 * 60 * 60 # seconds

  # How often the sweeper looks. Eviction at day granularity does not need a
  # sweep a minute.
  SWEEP_INTERVAL = 5 * 60 # seconds

  # --- Caching ---------------------------------------------------------------

  # Docs pages are static server-rendered markdown. A CDN can serve them for an
  # hour and keep serving the stale copy for a day while it refreshes in the
  # background, so a deploy propagates without a traffic spike reaching the app.
  DOCS_MAX_AGE = 60 * 60 # seconds
  DOCS_STALE_WHILE_REVALIDATE = 24 * 60 * 60 # seconds
end
