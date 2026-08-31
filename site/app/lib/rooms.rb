# Room bookkeeping around the real store.
#
# The documents themselves live in SQLite through the gem's own models — the
# channel's hooks are `Y::Document.load_state` / `Y::Document.append`, the
# canonical stack the docs teach. What that stack deliberately does not have is
# a notion of "rooms with limits", so this class carries the site's caps:
#
#   seats     who is currently in which room (peers per room, and the sweeper's
#             "don't evict an occupied room" check)
#   rooms     how many documents may exist at once (a disk cap now, not RAM)
#   size      how big one document may grow (the read-only-at-cap behavior)
#
# Seats and the size cache are process memory, which is exactly right for them:
# a seat dies with its connection, and every connection lives in this one
# node's embedded Go server. They are bookkeeping about the live process, not
# state worth persisting — the documents are in the database.
#
# Concurrency: shared across the RPC requests, which under Falcon are fibers
# switching at IO and scheduler yields, plus the sweeper thread. The mutex
# stays for the same reasons RoomStore's did — the reactor can serve requests
# concurrently, and an uncontended mutex costs nothing. DB reads happen outside
# the lock so a fiber never yields into SQLite while holding it.
class Rooms
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  attr_reader :max_peers, :max_rooms, :max_document_bytes

  def initialize(max_peers: Limits::MAX_PEERS_PER_ROOM,
                 max_rooms: Limits::MAX_LIVE_ROOMS,
                 max_document_bytes: Limits::MAX_DOCUMENT_BYTES,
                 size_cache_ttl: Limits::SIZE_CACHE_TTL)
    @max_peers = max_peers
    @max_rooms = max_rooms
    @max_document_bytes = max_document_bytes
    @size_cache_ttl = size_cache_ttl
    @seats = Hash.new(0)
    @sizes = {} # key => [bytes, refreshed_at]; see document_full?
    @mutex = Mutex.new
  end

  # Take a seat. :ok, :room_full past the per-room peer cap, or
  # :too_many_rooms when this would mint a new document and the process is at
  # the room cap. The count is a DB query, done before the lock; the cap is a
  # defense, not an invariant, so losing a race by one is fine.
  def join(key)
    new_room = !Y::Document.exists?(key: key)
    over_room_cap = new_room && Y::Document.count >= @max_rooms

    @mutex.synchronize do
      next :room_full if @seats[key] >= @max_peers
      next :too_many_rooms if over_room_cap && @seats[key].zero?

      @seats[key] += 1
      :ok
    end
  end

  def leave(key)
    @mutex.synchronize do
      next unless @seats.key?(key)

      @seats[key] -= 1
      @seats.delete(key) if @seats[key] <= 0
    end
    nil
  end

  def peers(key) = @mutex.synchronize { @seats[key] }

  def occupied_keys = @mutex.synchronize { @seats.keys }

  # The document size cap. The true size is state bytes plus tail bytes in the
  # database, but querying it on every frame would put a SUM on the hot path —
  # and querying it every few seconds would leave a flood window: at the frame
  # cap a hostile client can append megabytes between refreshes.
  #
  # So the cache works the other way round. `note_append` adds each accepted
  # update's bytes to the cached size the moment it is recorded, which keeps
  # the cap tight under any write rate with no query at all. The DB is only
  # consulted when the entry is stale (SIZE_CACHE_TTL) or missing — to pick up
  # compaction, which only ever shrinks the true size. Between refreshes the
  # cache can only over-estimate, and over-estimating a cap is the safe
  # direction: worst case a just-compacted room stays read-only a few extra
  # seconds.
  def document_full?(key)
    cached_size(key) >= @max_document_bytes
  end

  def note_append(key, bytes)
    @mutex.synchronize do
      entry = @sizes[key]
      entry[0] += bytes if entry
    end
    nil
  end

  # The sweeper evicted this room; its next write starts from zero.
  def forget(key)
    @mutex.synchronize { @sizes.delete(key) }
    nil
  end

  private

  def cached_size(key)
    now = monotonic
    entry = @mutex.synchronize { @sizes[key] }
    return entry[0] if entry && now - entry[1] < @size_cache_ttl

    bytes = query_size(key)
    @mutex.synchronize { @sizes[key] = [bytes, now] }
    bytes
  end

  def query_size(key)
    document = Y::Document.select(:id).find_by(key: key)
    return 0 unless document

    state = Y::Document.where(id: document.id).pick(Arel.sql("LENGTH(state)")) || 0
    state + document.updates.sum(Arel.sql("LENGTH(payload)")).to_i
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
