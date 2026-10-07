# frozen_string_literal: true

# Every limit this site enforces, with the reasoning for each number.
#
# The site is a public, anonymous collaborative demo that anyone can write to,
# so anyone can use up the process's memory and CPU. None of these limits is a
# security boundary on its own. Together they limit how much of one machine a
# stranger can use. The layers, from the outside in:
#
#   0. anycable-go           max WebSocket message size     (ANYCABLE_MAX_MESSAGE_SIZE)
#   0. anycable-go           max concurrent sockets         (ANYCABLE_MAX_CONN)
#   1. Rack::Attack          per-IP HTTP request rate       (rack_attack.rb)
#   2. ConnectionLimiter     concurrent WebSockets per IP   (connection.rb)
#   2. ConnectionGuard       subscriptions per WebSocket    (connection_guard.rb)
#   3. ConnectionGuard       frames per second per socket   (connection_guard.rb)
#   3. WriteBudget           document writes per second     (write_budget.rb, process-wide)
#   4. frame size cap        bytes per frame                (room_guarded.rb)
#   5. document size cap     bytes per room, total          (rooms.rb)
#   6. room caps             peers per room, rooms on disk  (rooms.rb)
#   7. idle eviction         stale rooms deleted            (room_sweeper.rb)
#   7. leak reaping          silent connections reaped      (connection_guard.rb)
#
# Awareness frames go through the same guarded `send` path as document frames,
# from layer 3 on. The demo doesn't use AnyCable whispers, which would relay
# frames from client to client and skip every layer here (see "Presence goes
# through send" in README.md, and RoomGuarded). Because awareness reaches Ruby,
# the layer 7 leak reaper can tell which connections are alive and free a
# leaked connection's seats and slot.
#
# Layer 0 runs in Go, in the anycable-go embedded in the thrust proxy, and is
# set by environment variables. Its message size is MAX_MESSAGE_BYTES below.
# Layers 2 through 6 run in Ruby, which anycable-go calls over HTTP RPC on
# connect and on every message.
#
# README.md ("Throttling") describes the whole design.
module Limits
  # --- HTTP (Rack::Attack) ---------------------------------------------------

  # A person reading docs loads a page every few seconds at most, and each page
  # is one HTML request plus static assets, which don't count. 60 a minute is
  # well above human browsing and still holds a scraper to one request per
  # second.
  PAGE_REQUESTS = Integer(ENV.fetch("PAGE_REQUESTS", 60))
  PAGE_PERIOD = 60 # seconds

  # There's no cable throttle here. /cable never passes through Rack, because
  # the embedded anycable-go answers it in the proxy, so a handshake limit here
  # would count nothing. MAX_CONNECTIONS_PER_IP below limits handshakes
  # instead, checked in Ruby on the Connect RPC.

  # --- Connections -----------------------------------------------------------

  # Opening a second window is the point of the site, and a curious visitor may
  # open one per demo. Eight is plenty for a person and cheap to hold. More than
  # that is a script. The env override is for load testing, where every
  # connection comes from one IP. Production leaves it unset.
  MAX_CONNECTIONS_PER_IP = Integer(ENV.fetch("MAX_CONNECTIONS_PER_IP", 8))

  # --- Subscriptions (per physical connection) -------------------------------
  #
  # One WebSocket can open many channel subscriptions, and every subscription
  # takes a room seat and can create a document. Without a per-connection cap,
  # one socket could subscribe to thousands of different rooms and create a
  # document in each. The room cap counts a brand-new key only when it's first
  # seated, so it wouldn't stop that. These limit how far one socket can reach.

  # Concurrent subscriptions one connection may hold. A person opens one room per
  # page and a handful of pages. Twenty is plenty for that and far below what a
  # script would need. With the per-IP connection cap of 8, one address can hold
  # at most 160 rooms at once, well under MAX_LIVE_ROOMS.
  MAX_SUBSCRIPTIONS_PER_CONNECTION = Integer(ENV.fetch("MAX_SUBSCRIPTIONS_PER_CONNECTION", 20))

  # Rate limit on `subscribe` commands from one connection, as a token bucket.
  # Opening a page is one subscribe, and clicking quickly through every demo is
  # a few per second. The burst covers a reconnect that re-subscribes all of a
  # client's open tabs. The sustained rate stops a socket from cycling through
  # rooms with repeated subscribe and unsubscribe.
  SUBSCRIBES_PER_SECOND = 5
  SUBSCRIBE_BURST = 20

  # Process-wide ceiling. Ruby holds nothing between messages, so an open socket
  # costs a goroutine and its buffers in anycable-go, around 10 KB. An Action
  # Cable connection object in Ruby costs about 50 KB. 500 is a conservative
  # ceiling for a 1 GB machine that also runs the document store. The sockets
  # aren't what runs out first. The env override is for load testing, as above.
  MAX_CONNECTIONS = Integer(ENV.fetch("MAX_CONNECTIONS", 500))

  # How long a connection can go silent before the guard treats it as leaked
  # and frees its room seats and connection slot. `release` normally frees a
  # slot as soon as the Disconnect RPC arrives. This covers the case where that
  # RPC never arrives (a dropped socket, a network partition). The clock resets
  # on every frame the server sees, document update or awareness, since the demo
  # sends awareness through `send`. yrby-client re-sends awareness on a
  # heartbeat (about every 15s), well under this hour, so a reader with an idle
  # tab open isn't reaped. Only a dead connection is. See ConnectionGuard.
  CONNECTION_SLOT_TTL = 60 * 60 # seconds

  # --- Frames ----------------------------------------------------------------

  # Largest single frame accepted, in decoded bytes. yrby's default is 8 MiB,
  # sized for a large initial SyncStep2 in a real app. Demo documents are tiny,
  # and the whole room is capped at MAX_DOCUMENT_BYTES, so this is set well
  # above any real demo edit and far below the default. anycable-go checks the
  # size at the socket (ANYCABLE_MAX_MESSAGE_SIZE), and yrby checks it again in
  # Ruby. The two limits measure different things. Ruby caps the *decoded*
  # update, and anycable-go caps the whole *encoded* message (base64 is about
  # 4/3 the size, plus the JSON envelope). So the Go limit is higher (see
  # MAX_MESSAGE_BYTES below), and Go doesn't refuse a valid update before Ruby
  # checks it.
  MAX_FRAME_BYTES = 128 * 1024

  # The value for ANYCABLE_MAX_MESSAGE_SIZE (set in the Dockerfile and
  # frontend/boot_server.sh). It limits the whole encoded WebSocket message, so
  # it has to fit a MAX_FRAME_BYTES update after base64 expansion (4/3) plus the
  # JSON envelope (`{"update":"…","id":N}`). 192 KiB is above
  # RoomGuarded::MAX_ENCODED_BYTES (about 171 KiB) with room for the envelope.
  # Any smaller, and Go would refuse a valid max-size update before the RPC. Go
  # reads the value from the environment, but it's defined here so it sits
  # next to the other frame limits.
  MAX_MESSAGE_BYTES = 192 * 1024

  # A process-wide ceiling on document writes per second, checked before they
  # reach SQLite. Every accepted document frame is an insert into single-writer
  # SQLite. The per-connection buckets limit each client, but all clients
  # together, even within their caps, can send far more than one SQLite file
  # handles before SQLITE_BUSY starts slowing page requests. Past this limit the
  # server drops document frames. The client keeps the update queued and
  # retries it, as with any other dropped frame, so a flood slows writes down
  # without locking up the database. Awareness frames don't count. A full room
  # typing as fast as it can is a few dozen writes a second, so real use stays
  # well under this.
  DOCUMENT_WRITES_PER_SECOND = Integer(ENV.fetch("DOCUMENT_WRITES_PER_SECOND", 400))
  DOCUMENT_WRITE_BURST = Integer(ENV.fetch("DOCUMENT_WRITE_BURST", 800))

  # Frame token bucket, one per connection (see ConnectionGuard). Typing sends a
  # handful of frames a second. Dragging a whiteboard note or moving a caret
  # sends awareness frames at about pointer-event rate. 40 a second covers both
  # with room to spare, and the burst of 120 covers the frames that arrive
  # together when a client joins.
  FRAMES_PER_SECOND = 40
  FRAME_BURST = 120

  # The server drops frames from a client that's over its bucket. Some of that
  # is normal, such as a burst of awareness during a fast drag. A connection
  # that keeps going past this many dropped frames, across all its
  # subscriptions, isn't a person using a browser, so the server closes it.
  FRAME_DROPS_BEFORE_CLOSE = 200

  # --- Documents and rooms ---------------------------------------------------
  #
  # The store is Y::Document on SQLite, and no document state stays in process
  # memory between messages, so these caps limit disk use and content. The gem
  # handles compaction (Y::Document.compact_every, default 64 tail rows), so
  # there's no compaction constant here.

  # Total bytes of CRDT state stored for one room: the compacted snapshot plus
  # the uncompacted tail. A demo document, such as a page of rich text or a few
  # dozen spreadsheet cells, is tens of kilobytes with its history. 512 KiB is
  # about ten times that. A room at the cap stops accepting document writes,
  # and the page says so.
  MAX_DOCUMENT_BYTES = 512 * 1024

  # Documents on disk at once. 2000 x MAX_DOCUMENT_BYTES puts a 1 GB ceiling on
  # the database file, which fits on any volume. Rooms last a day before the
  # sweeper deletes them, so they pile up, and they use disk, not memory.
  MAX_LIVE_ROOMS = 2000

  # Peers in one room. More than a dozen carets in a demo document is
  # unreadable, and the server sends every update to each peer.
  MAX_PEERS_PER_ROOM = Integer(ENV.fetch("MAX_PEERS_PER_ROOM", 12))

  # How old the cached per-room size can get before Rooms re-reads it from the
  # database. Rooms#reserve_write adds each write to the cache right away, so a
  # stale entry can only overestimate. The refresh picks up compaction, which
  # shrinks the true size. See Rooms#document_full?.
  SIZE_CACHE_TTL = 30 # seconds

  # A room with no writes and nobody in it for this long is deleted, rows and
  # all. Rooms are public and anonymous, and the site tells visitors they're
  # temporary. With a day, a link shared in the morning still works after
  # dinner, and nothing anyone pastes lasts longer than that.
  ROOM_IDLE_TTL = 24 * 60 * 60 # seconds

  # How often the sweeper runs. Rooms expire after a day, so there's no need to
  # sweep every minute.
  SWEEP_INTERVAL = 5 * 60 # seconds

  # --- Caching ---------------------------------------------------------------

  # Docs pages are server-rendered markdown that doesn't change between
  # visitors. A CDN can serve them for an hour, then serve the stale copy for up
  # to a day while it refreshes in the background. After a deploy, the new
  # pages reach readers without a burst of traffic hitting the app.
  DOCS_MAX_AGE = 60 * 60 # seconds
  DOCS_STALE_WHILE_REVALIDATE = 24 * 60 * 60 # seconds
end
