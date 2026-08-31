# The whole storage layer for this site: a Hash of rooms in process memory.
#
# yrby's channel concern only needs `on_load` and `on_change` answered, and
# nothing says they have to touch a database. This is that, made concrete —
# ephemeral collaborative documents with no Postgres, no Redis, and no disk.
#
# Two consequences, both deliberate:
#
#   * The site is ONE process. The store is not shared, and the cable adapter is
#     `async` (in-process), so a second process would serve different documents
#     under the same URL. Scaling this app out means swapping this class for a
#     shared store and the adapter for redis/solid_cable, which is the point of
#     the hooks being swappable.
#   * Documents die with the process. A restart or a scale-to-zero stop drops
#     every room. Reconnecting browsers re-seed the server through the ordinary
#     sync handshake, so a room whose tab is still open comes back; one whose
#     tabs are all closed is gone.
#
# The load path is lossless on purpose. `on_load` replays the snapshot plus the
# raw tail and returns `encode_state_as_update`, which keeps pending structs, so
# an update that arrived before the update it depends on still heals when the
# missing one lands. Compaction is the one place that must not carry pending, so
# it uses `compacted_state_update` and skips while `doc.pending?`.
#
# Concurrency: the store is shared. Under Falcon the RPC requests that reach it
# are fibers on one thread — context switches happen at IO and scheduler yields,
# not preemptively — and the sweeper is a plain Thread on top of that. The
# mutexes stay for both reasons: a fiber CAN yield mid-sequence anywhere IO
# happens, the reactor is free to run requests concurrently, and a mutex that is
# never contended costs nothing. Nothing in this file is safe by accident of the
# server's scheduling model.
#
# Every limit is a constructor keyword defaulting to config/limits.rb, so the
# tests can build a small store instead of writing half a megabyte at one.
class RoomStore
  # Raised by `append` when a room is already at its byte cap. This is a
  # backstop, not the enforcement point: DocumentChannel checks `full?` before
  # it hands a frame to yrby, so an over-cap write is dropped before it reaches
  # `on_change`. Raising inside `on_change` rejects the update without acking
  # it, and an unacked update is retransmitted forever — fine for a bug, wrong
  # as a routine path.
  class DocumentFull < StandardError; end

  # One document plus its bookkeeping. Mutable, and every mutation holds the
  # room's own mutex; the store's mutex only guards the room table.
  class Room
    attr_reader :key, :peers

    def initialize(key, max_bytes:, compact_every:)
      @key = key
      @max_bytes = max_bytes
      @compact_every = compact_every
      @state = nil        # compacted snapshot, or nil for a fresh document
      @tail = []          # raw updates appended since the snapshot
      @bytes = 0          # @state plus @tail, the number max_bytes caps
      @peers = 0
      @mutex = Mutex.new
      @touched_at = RoomStore.now
    end

    # Lossless full state for the sync handshake, or nil for a fresh document.
    def load
      @mutex.synchronize do
        @touched_at = RoomStore.now
        next @state if @tail.empty?

        replay.encode_state_as_update
      end
    end

    def append(update)
      @mutex.synchronize do
        raise DocumentFull, "#{@key} is at #{@bytes} bytes" if @bytes >= @max_bytes

        @tail << update
        @bytes += update.bytesize
        @touched_at = RoomStore.now
        compact if @tail.length >= @compact_every
        :ok
      end
    end

    def full? = @mutex.synchronize { @bytes >= @max_bytes }

    def bytes = @mutex.synchronize { @bytes }

    def idle_for(now = RoomStore.now) = now - @touched_at

    # join/leave are called under the store's mutex, so the peer count can't
    # race a sweep.
    def join
      @peers += 1
      @touched_at = RoomStore.now
    end

    def leave
      @peers -= 1 if @peers.positive?
      @touched_at = RoomStore.now
    end

    private

    def replay
      doc = Y::Doc.new
      doc.apply_update(@state) if @state
      @tail.each { |update| doc.apply_update(update) }
      doc
    end

    # Fold the tail into one snapshot so loads stay cheap. `compacted_state_update`
    # is gap-free, which is what a snapshot has to be — folding a pending struct
    # into the base state would freeze an un-integrable block there forever. So
    # while the document is waiting on a missing update, the tail keeps growing
    # instead (bounded by max_bytes) and compaction retries on the next append.
    def compact
      doc = replay
      return if doc.pending?

      @state = doc.compacted_state_update
      @tail.clear
      @bytes = @state.bytesize
    end
  end

  class << self
    attr_writer :current

    def current = @current ||= new

    # Monotonic seconds. A wall-clock jump must not make a room look idle.
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  attr_reader :max_document_bytes, :max_rooms, :max_peers, :idle_ttl

  def initialize(max_document_bytes: Limits::MAX_DOCUMENT_BYTES,
                 max_rooms: Limits::MAX_LIVE_ROOMS,
                 max_peers: Limits::MAX_PEERS_PER_ROOM,
                 idle_ttl: Limits::ROOM_IDLE_TTL,
                 compact_every: Limits::COMPACT_EVERY)
    @max_document_bytes = max_document_bytes
    @max_rooms = max_rooms
    @max_peers = max_peers
    @idle_ttl = idle_ttl
    @compact_every = compact_every
    @rooms = {}
    @mutex = Mutex.new
  end

  # Take a seat in a room, creating it if needed. Returns :ok, :room_full when
  # the room already holds max_peers, or :too_many_rooms when the process is
  # already holding max_rooms.
  def join(key)
    @mutex.synchronize do
      room = @rooms[key]
      if room.nil?
        next :too_many_rooms if @rooms.size >= @max_rooms

        room = @rooms[key] = build_room(key)
      end
      next :room_full if room.peers >= @max_peers

      room.join
      :ok
    end
  end

  def leave(key)
    @mutex.synchronize { @rooms[key]&.leave }
    nil
  end

  # on_load. nil means "fresh document" — including for a room that has been
  # evicted, which is exactly right: the first client to reconnect re-seeds it.
  def load(key) = self[key]&.load

  # on_change. Creates the room if a write lands before a join (or after an
  # eviction) and there is room on the box for it.
  def append(key, update)
    room = self[key] || create(key)
    raise DocumentFull, "no room for #{key}" if room.nil?

    room.append(update)
  end

  def full?(key) = self[key]&.full? || false

  def bytes(key) = self[key]&.bytes || 0

  def peers(key) = @mutex.synchronize { @rooms[key]&.peers || 0 }

  def live_rooms = @mutex.synchronize { @rooms.size }

  # Drop rooms nobody is in and nobody has written to for idle_ttl. Returns the
  # keys evicted.
  def sweep(now = RoomStore.now)
    @mutex.synchronize do
      evicted = @rooms.select { |_, room| room.peers.zero? && room.idle_for(now) >= @idle_ttl }.keys
      evicted.each { |key| @rooms.delete(key) }
      evicted
    end
  end

  def stats
    @mutex.synchronize do
      { rooms: @rooms.size, peers: @rooms.sum { |_, room| room.peers } }
    end
  end

  private

  def [](key) = @mutex.synchronize { @rooms[key] }

  def build_room(key) = Room.new(key, max_bytes: @max_document_bytes, compact_every: @compact_every)

  def create(key)
    @mutex.synchronize do
      next @rooms[key] if @rooms.key?(key)
      next nil if @rooms.size >= @max_rooms

      @rooms[key] = build_room(key)
    end
  end
end
