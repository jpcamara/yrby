# Tracks rooms and their limits.
#
# The documents live in SQLite through the gem's models. The channel's hooks
# are `Y::Document.load_state` and `Y::Document.append`, the same setup the
# docs describe. The gem's models don't know about rooms or limits, so this
# class keeps track of the site's caps:
#
#   seats     who is in which room right now (peers per room, and the
#             sweeper's check that a room is empty before it's deleted)
#   rooms     how many documents can exist at once (a disk limit)
#   size      how large one document can grow (the room goes read-only at
#             the cap)
#
# Seats and the size cache live in process memory. A seat goes away when its
# connection closes, and every connection runs through this server's embedded
# Go process, so there's nothing here worth saving. The documents themselves
# are in the database.
#
# The room cap counts more than saved rows. A document isn't created until a
# room's first append, but a subscription takes a seat as soon as it joins.
# Without extra tracking, a flood of `subscribe` commands for different valid
# keys would all be let in (none of their rows exist yet) and then each create
# a document, going over the cap. So a new key with a seat counts as a
# reservation until its document exists (first append) or its last occupant
# leaves. The cap applies to saved rows plus live reservations.
#
# Concurrency: the RPC requests share this object. Under Falcon they're fibers
# that switch at IO and scheduler yields, and the sweeper thread uses it too.
# The reactor can serve requests concurrently, so the mutex is needed, and an
# uncontended mutex is cheap. Database reads happen outside the lock so a
# fiber never waits on SQLite while holding it.
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
    @reserved = Set.new # new seated keys whose document doesn't exist yet
    @evicting = Set.new # keys the sweeper has claimed and will delete
    @sizes = {} # key => [bytes, refreshed_at]; see document_full?
    @mutex = Mutex.new
  end

  # Takes a seat. Returns :ok, :room_full when the room is at its peer cap,
  # :too_many_rooms when this is a new room and saved plus reserved rooms are
  # at the cap, or :evicting when the sweeper has claimed the key for deletion.
  #
  # The saved count comes from a database query before the lock. The cap is a
  # safeguard, so being off by one in a race is fine. A new key that's let in
  # gets reserved inside the lock, so concurrent joins for different new keys
  # count each other and can't all get in under a stale count.
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
      next if @seats[key].positive?

      @seats.delete(key)
      @reserved.delete(key) # last occupant left a room that was never saved
    end
    nil
  end

  def peers(key) = @mutex.synchronize { @seats[key] }

  def occupied_keys = @mutex.synchronize { @seats.keys }

  # Returns true if the budget allows one more new room right now. It uses the
  # same count `join` applies to a new key: saved documents plus live
  # reservations, against the cap.
  #
  # NoteChannel calls this before it creates a Note row on subscribe. A Note's
  # document key includes the row id, so the key doesn't exist until the row
  # does. This checks the budget first, and `join` makes the real reservation
  # once the key exists. Like `join`, it can be off by one in a race, and
  # that's fine.
  def room_available?
    Y::Document.count + @mutex.synchronize { @reserved.size } < @max_rooms
  end

  # The document size cap. The real size is the state bytes plus the update
  # bytes in the database. Running that SUM on every frame would slow down the
  # hot path. Running it every few seconds would leave a gap where a hostile
  # client at the frame cap could append megabytes between checks.
  #
  # So `reserve_write` adds each accepted update's bytes to the cached size as
  # soon as it's let in, before it's saved. That keeps the cap tight at any
  # write rate without a query. The database is only read when the entry is
  # missing or older than SIZE_CACHE_TTL, to pick up compaction. Compaction
  # only makes a document smaller, so between reads the cache can only
  # overestimate. Overestimating is the safe direction for a cap. At worst, a
  # room that was just compacted stays read-only for a few more seconds.
  def document_full?(key)
    cached_size(key) >= @max_document_bytes
  end

  # Either lets in one document write of `bytes` and counts it, or refuses it,
  # in one atomic step. It checks `current + bytes` against the cap, so the
  # update that would go over the cap is the one refused. The check happens
  # under the lock, so two writes racing toward the cap can't both get in.
  # `cached_size` may read the database outside the lock to refresh a stale
  # entry. This method reads the entry again inside the lock, so the counting
  # stays serialized.
  def reserve_write(key, bytes)
    current = cached_size(key)
    @mutex.synchronize do
      entry = @sizes[key]
      live = entry ? entry[0] : current
      next false if live + bytes > @max_document_bytes

      # Keep the entry's refreshed_at (or set one) so a stale entry still
      # triggers a database read that picks up compaction.
      @sizes[key] = [live + bytes, entry ? entry[1] : monotonic]
      # The append creates the row, so after a write the key counts as a saved
      # document and not a reservation.
      @reserved.delete(key)
      true
    end
  end

  # Called after the sweeper deletes this room. Its next write starts from
  # zero.
  def forget(key)
    @mutex.synchronize do
      @sizes.delete(key)
      @evicting.delete(key)
    end
    nil
  end

  # Coordinates eviction with RoomSweeper. From the sweeper's stale
  # candidates, this claims the keys that have no occupant and no reservation,
  # under the lock. It marks them as evicting, so a concurrent join gets
  # :evicting and a concurrent write can't reopen them. It returns the claimed
  # keys. The caller checks the database again, deletes the keys that are
  # still stale, and calls `forget` on each claimed key to clear the mark.
  #
  # The seat check and the claim happen in one locked step. If a join got
  # there first, it holds a seat and the key isn't claimed. If the claim got
  # there first, the join sees the mark and is refused. So a room that someone
  # is in or joining is never claimed.
  def claim_evictions(candidate_keys)
    @mutex.synchronize do
      candidate_keys.select do |key|
        next false unless @seats[key].zero? && !@reserved.include?(key)

        @evicting << key
        true
      end
    end
  end

  def evicting?(key) = @mutex.synchronize { @evicting.include?(key) }

  private

  # The caller holds the mutex. A new key (no seat, no saved document, no
  # reservation) has to fit under the cap, and then it's reserved. Every other
  # join, to a room with a seat or a saved document, is let in.
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
      # Another fiber may have added a reservation while we queried. Keep the
      # larger value, because overestimating is the safe direction for a cap.
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
