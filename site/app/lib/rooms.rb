# Starts rooms and seats people in their documents, within the site's caps:
#
#   rooms          how many rooms can exist at once (a disk limit)
#   peers          how many connections one document takes
#   subscriptions  how many documents one connection can be in
#   size           how large one document can grow (the document goes
#                  read-only at the cap)
#
# Rooms and seats are rows (Room, Seat), so every server process counts the
# same ones. `start` and `join` each run in one transaction, and Rails begins
# SQLite transactions IMMEDIATE, so two processes can't both take the last
# room or the last seat. The sweeper deletes rooms and documents in
# transactions too, so a join can't seat someone in a room as it's deleted.
#
# The size cache lives in process memory. Each process adds the writes it lets
# in and re-reads the database every SIZE_CACHE_TTL, so with several processes
# a document can go past its cap by what the others wrote in that window.
#
# Concurrency: the RPC requests share this object. Under Falcon they're fibers
# that switch at IO and scheduler yields, and the sweeper thread uses it too,
# so the size cache sits behind a mutex. Database reads happen outside the lock
# so a fiber never waits on SQLite while holding it.
class Rooms
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  attr_reader :max_peers, :max_rooms, :max_subscriptions, :max_document_bytes

  def initialize(max_peers: Limits::MAX_PEERS_PER_ROOM,
                 max_rooms: Limits::MAX_LIVE_ROOMS,
                 max_subscriptions: Limits::MAX_SUBSCRIPTIONS_PER_CONNECTION,
                 max_document_bytes: Limits::MAX_DOCUMENT_BYTES,
                 size_cache_ttl: Limits::SIZE_CACHE_TTL)
    @max_peers = max_peers
    @max_rooms = max_rooms
    @max_subscriptions = max_subscriptions
    @max_document_bytes = max_document_bytes
    @size_cache_ttl = size_cache_ttl
    @sizes = {} # key => [bytes, refreshed_at]; see document_full?
    @mutex = Mutex.new
  end

  # The room `slug` names, created if the room cap allows another. nil when
  # there's no such room and the site has all the rooms it holds.
  def start(slug)
    Room.transaction do
      Room.find_by(slug:) || (Room.create!(slug:) if Room.count < @max_rooms)
    end
  end

  # Seats `connection_id` in `record`'s document `name`. Returns :ok,
  # :duplicate when the connection is already in that document, :too_many when
  # it's in as many documents as it may be, :room_full at the peer cap, or
  # :gone when the record was deleted after the channel found it.
  def join(record, name, connection_id)
    Seat.transaction do
      seats = Seat.where(room: record, name: name.to_s)
      next :gone unless record.class.exists?(record.id)
      next :duplicate if seats.exists?(connection_id:)
      next :too_many if Seat.where(connection_id:).count >= @max_subscriptions
      next :room_full if seats.count >= @max_peers

      seats.create!(connection_id:, seen_at: Time.current)
      :ok
    end
  end

  def leave(record, name, connection_id)
    Seat.where(room: record, name: name.to_s, connection_id:).delete_all
    nil
  end

  # Gives back every seat a closed connection still holds.
  def leave_all(connection_id)
    Seat.where(connection_id:).delete_all
    nil
  end

  # Marks a connection's seats as still in use. See Seat.
  def seen(connection_id)
    Seat.where(connection_id:).update_all(seen_at: Time.current)
    nil
  end

  def peers(record, name) = Seat.where(room: record, name: name.to_s).count

  # The document size cap. The real size is the state bytes plus the update
  # bytes in the database. Running that SUM on every frame would slow down the
  # hot path. Running it every few seconds would leave a gap where a hostile
  # client at the frame cap could append megabytes between checks.
  #
  # So `reserve_write` adds each accepted update's bytes to the cached size as
  # soon as it's let in, before it's saved. That keeps the cap tight at any
  # write rate without a query. The database is only read when the entry is
  # missing or older than SIZE_CACHE_TTL, to pick up compaction and other
  # processes' writes. Between reads, the cache misses other processes' writes
  # (see above), and after a compaction it overestimates, so a document that
  # was just compacted can stay read-only for a few more seconds.
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
      true
    end
  end

  # Called after the sweeper deletes a document. Its next write starts from
  # zero.
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
