# frozen_string_literal: true

# Every limit this site enforces, with the reasoning for the number.
#
# The site is a public, anonymous, write-open collaborative demo, which is an
# open door to the process's memory and CPU. Nothing here is a security
# boundary on its own; together they bound how much of one machine a stranger
# can take. The layers are, from outside in:
#
#   1. Rack::Attack          per-IP HTTP request rate       (rack_attack.rb)
#   2. ConnectionLimiter     concurrent WebSockets per IP   (connection.rb)
#   3. TokenBucket           frames per second per client   (document_channel.rb)
#   4. frame size cap        bytes per frame                (document_channel.rb)
#   5. document size cap     bytes per room, total          (room_store.rb)
#   6. room caps             peers per room, rooms per box  (room_store.rb)
#   7. idle eviction         rooms dropped when untouched   (room_sweeper.rb)
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

  # The cable handshake is the expensive request: it upgrades to a WebSocket and
  # allocates a connection for as long as it is held. A person opening two
  # windows on a demo makes two. 12/minute covers reloading a demo page every
  # five seconds; a reconnect storm from one address stops there.
  CABLE_HANDSHAKES = 12
  CABLE_PERIOD = 60 # seconds

  # --- Connections -----------------------------------------------------------

  # "Open a second window" is the whole point of the site, and a curious visitor
  # may open one per demo. Eight is generous for a person and cheap to hold;
  # past that it is a script.
  MAX_CONNECTIONS_PER_IP = 8

  # Process-wide ceiling. A Falcon fiber plus an Action Cable connection object
  # and its socket buffers is roughly 50 KB, so 500 is about 25 MB of
  # connection overhead — affordable on a 1 GB machine next to the document
  # store's own ceiling below.
  MAX_CONNECTIONS = 500

  # --- Frames ----------------------------------------------------------------

  # Largest single frame accepted, in decoded bytes. yrby's own default is
  # 8 MiB, sized for a large initial SyncStep2 in a real app. Demo documents are
  # tiny, and the whole room is capped at MAX_DOCUMENT_BYTES anyway, so this is
  # cut to a size a legitimate demo edit never approaches.
  MAX_FRAME_BYTES = 128 * 1024

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

  # Total bytes of CRDT state held for one room: the compacted snapshot plus the
  # uncompacted tail. A demo document — a page of rich text, a few dozen
  # spreadsheet cells — is tens of kilobytes with its history. 512 KiB is about
  # ten times that. A room at the cap stops accepting document writes and says
  # so on the page; it does not grow until the process dies.
  MAX_DOCUMENT_BYTES = 512 * 1024

  # Rooms held in memory at once. 200 x MAX_DOCUMENT_BYTES is a 100 MB ceiling
  # on the store, which sits inside a 1 GB machine alongside Rails and the
  # connection overhead above.
  MAX_LIVE_ROOMS = 200

  # Peers in one room. More than a dozen carets in a demo document is unreadable
  # anyway, and each peer is another fan-out target for every update.
  MAX_PEERS_PER_ROOM = 12

  # Updates appended before the room's log is folded into one snapshot. Same
  # default Y::Document uses (64), halved: this store replays the whole log on
  # every load, so a shorter tail keeps loads cheap.
  COMPACT_EVERY = 32

  # A room with no peers and no writes for this long is dropped from memory.
  # Long enough that closing a tab and coming back with the link still finds the
  # document; short enough that an abandoned room is not held all day.
  ROOM_IDLE_TTL = 20 * 60 # seconds

  # How often the sweeper looks for idle rooms.
  SWEEP_INTERVAL = 60 # seconds

  # --- Caching ---------------------------------------------------------------

  # Docs pages are static server-rendered markdown. A CDN can serve them for an
  # hour and keep serving the stale copy for a day while it refreshes in the
  # background, so a deploy propagates without a traffic spike reaching the app.
  DOCS_MAX_AGE = 60 * 60 # seconds
  DOCS_STALE_WHILE_REVALIDATE = 24 * 60 * 60 # seconds
end
