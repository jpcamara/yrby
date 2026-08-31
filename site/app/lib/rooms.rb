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
# The room cap counts more than persisted rows. A document is not created until
# a room's first append, but a subscription holds a seat from the moment it
# joins — so a flood of `subscribe` commands for distinct valid keys would all
# be admitted (each key's row is still absent) and then mint a document apiece,
# walking past the cap. So a brand-new seated key is a *reservation*: it counts
# against the cap until its document exists (first append) or its last occupant
# leaves. Persisted rows plus live reservations is what the cap bounds.
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
    @reserved = Set.new # brand-new seated keys whose document doesn't exist yet
    @evicting = Set.new # keys the sweeper has claimed and is about to delete
    @sizes = {} # key => [bytes, refreshed_at]; see document_full?
    @mutex = Mutex.new
  end

  # Take a seat. :ok, :room_full past the per-room peer cap, :too_many_rooms
  # when this would introduce a new room and persisted+reserved is at the cap,
  # or :evicting when the sweeper has claimed this key for deletion.
  #
  # The persisted count is a DB query, done before the lock; the cap is a
  # defense, not an invariant, so losing a race by one is fine. A new key that
  # is admitted is reserved inside the lock, so concurrent joins for distinct
  # new keys count each other and cannot all slip under a stale count.
  def join(key)
    new_room = !Y::Document.exists?(key: key)
    persisted = new_room ? Y::Document.count : nil

    @mutex.synchronize do
      next :evicting if @evicting.include?(key)
      next :room_full if @seats[key] >= @max_peers
      next :too_many_rooms unless admit_new_room?(key, new_room, persisted)

      @seats[key] += 1
      :ok
    end
  end

  def leave(key)
    @mutex.synchronize do
      next unless @seats.key?(key)

      @seats[key] -= 1
      if @seats[key] <= 0
        @seats.delete(key)
        @reserved.delete(key) # last occupant of a never-persisted room: free it
      end
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
  # So the cache works the other way round. `reserve_write` adds each accepted
  # update's bytes to the cached size the moment it is admitted — before it is
  # persisted — which keeps the cap tight under any write rate with no query at
  # all. The DB is only consulted when the entry is stale (SIZE_CACHE_TTL) or
  # missing — to pick up compaction, which only ever shrinks the true size.
  # Between refreshes the cache can only over-estimate, and over-estimating a
  # cap is the safe direction: worst case a just-compacted room stays read-only
  # a few extra seconds.
  def document_full?(key)
    cached_size(key) >= @max_document_bytes
  end

  # Atomically admit one document write of `bytes` and account for it, or
  # refuse. Prospective — it reserves `current + bytes` and rejects when that
  # would exceed the cap, so the update that *crosses* the cap is the one turned
  # away, not the one after it. The reservation happens under the lock, so two
  # writes racing toward the cap can't both be admitted. `cached_size` may read
  # the database (outside the lock) to refresh a stale entry; the reserve then
  # re-reads the entry inside the lock, so the accounting stays serialized.
  def reserve_write(key, bytes)
    current = cached_size(key)
    @mutex.synchronize do
      entry = @sizes[key]
      live = entry ? entry[0] : current
      next false if live + bytes > @max_document_bytes

      # Keep the entry's refreshed_at (or stamp a new one) so staleness still
      # triggers a DB re-read to pick up compaction.
      @sizes[key] = [live + bytes, entry ? entry[1] : monotonic]
      # A write proves the document now exists (append creates the row), so the
      # key is no longer a pending reservation — it counts as a real row.
      @reserved.delete(key)
      true
    end
  end

  # The sweeper evicted this room; its next write starts from zero.
  def forget(key)
    @mutex.synchronize do
      @sizes.delete(key)
      @evicting.delete(key)
    end
    nil
  end

  # Eviction coordination (see RoomSweeper). Given the sweeper's stale
  # candidates, claim under the lock exactly those with no occupant and no
  # reservation, marking them evicting so a concurrent join is refused
  # (:evicting) and a racing write cannot re-open them. Returns the claimed
  # keys; the caller re-checks database freshness and deletes only those still
  # stale, then calls `forget` on each to drop the mark.
  #
  # The seat check and the claim are one atomic step: a join that beat the claim
  # left a seat, which excludes the key here; a join that lost sees the mark and
  # is refused. Either way a live or joining room is never claimed.
  def claim_evictions(candidate_keys)
    @mutex.synchronize do
      candidate_keys.select do |key|
        next false unless @seats[key].zero?
        next false if @reserved.include?(key)

        @evicting << key
        true
      end
    end
  end

  def evicting?(key) = @mutex.synchronize { @evicting.include?(key) }

  private

  # Caller holds the mutex. A brand-new key (no seat, no persisted document, no
  # existing reservation) has to fit under the cap and is then reserved; every
  # other join — an existing seat, an existing document — is always admitted.
  def admit_new_room?(key, new_room, persisted)
    return true unless @seats[key].zero? && new_room && !@reserved.include?(key)
    return false if persisted + @reserved.size >= @max_rooms

    @reserved << key
    true
  end

  def cached_size(key)
    now = monotonic
    entry = @mutex.synchronize { @sizes[key] }
    return entry[0] if entry && now - entry[1] < @size_cache_ttl

    bytes = query_size(key)
    @mutex.synchronize do
      # Don't clobber a reservation another fiber added while we queried; keep the
      # larger, since over-estimating a cap is the safe direction.
      kept = [bytes, @sizes[key]&.first || 0].max
      (@sizes[key] = [kept, now]).first
    end
  end

  def query_size(key)
    document = Y::Document.select(:id).find_by(key: key)
    return 0 unless document

    state = Y::Document.where(id: document.id).pick(Arel.sql("LENGTH(state)")) || 0
    state + document.updates.sum(Arel.sql("LENGTH(payload)")).to_i
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
