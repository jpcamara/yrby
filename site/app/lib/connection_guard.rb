# Per-connection limits: what one physical WebSocket may do across all of its
# subscriptions.
#
# ConnectionLimiter caps how many sockets an address holds. This caps what one
# socket can spend once it is open, and it is keyed to the connection rather
# than to a subscription on purpose: the flaws it closes are all about a socket
# that opens many subscriptions:
#
#   subscriptions  a hard count, so one socket can't subscribe to thousands of
#                  distinct rooms (each of which would take a seat and could
#                  mint a document, walking past the room cap).
#   subscribe rate a token bucket on `subscribe` commands, so a socket can't
#                  churn subscribe/unsubscribe to cycle through rooms.
#   frames         ONE frame bucket for the whole connection. A per-subscription
#                  bucket resets on every subscribe and multiplies with the
#                  number of subscriptions, a socket could reset its burst by
#                  re-subscribing, or run N buckets' worth of rate at once. One
#                  bucket per socket has neither hole.
#   one seat/room  a connection may hold at most one seat in a given room, so it
#                  can't take every peer slot in a room by itself.
#
# Keyed by connection_id, which is minted in ApplicationCable::Connection#connect
# and travels as a connection identifier, so it is the same string on every
# command of a connection (and is available in channel tests). The guard is
# dropped on the Disconnect RPC; `sweep` reaps a guard whose disconnect never
# arrived, on the RoomSweeper's cadence.
#
# The guard is also this node's LIVENESS record for a connection, and the only
# safe leak backstop for its room seats and its connection slot. `seen_at` is
# stamped on every server-visible frame, a document update OR an awareness
# frame (awareness reaches Ruby now that the demo routes it through `send`
# instead of a whisper). A live viewer, even one only reading, keeps its clock
# fresh: yrby-client re-emits its awareness on a heartbeat (~every 15s, well
# under the TTL), so an idle-but-open tab stays visibly alive. A connection
# silent past CONNECTION_SLOT_TTL is therefore a genuine leak (the Disconnect
# RPC never arrived), and the sweep reaps it: it releases the connection's room
# seats (freeing the room's peer slot and dropping it from occupied_keys, so the
# room sweeper can evict a truly-abandoned room) and its connection slot, then
# forgets the guard. Reaping a still-live connection can only ever loosen a cap,
# never wrongly reject, the safe direction, and anycable-go's own
# ANYCABLE_MAX_CONN is the hard ceiling underneath all of this.
class ConnectionGuard
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  # One connection's live budget. Not serialized: this registry is process
  # memory, like the seats and the connection slots, and every connection lives
  # in this one node.
  class Guard
    attr_accessor :seen_at, :ip, :slot_token

    def initialize(max_subscriptions:, now:)
      @max_subscriptions = max_subscriptions
      @subscribe = TokenBucket.new(capacity: Limits::SUBSCRIBE_BURST,
                                   refill_per_second: Limits::SUBSCRIBES_PER_SECOND, now: now)
      @frames = TokenBucket.new(capacity: Limits::FRAME_BURST,
                                refill_per_second: Limits::FRAMES_PER_SECOND, now: now)
      @keys = Set.new
      @seen_at = now
    end

    # The rooms this connection is seated in, a snapshot the reaper releases
    # when the guard is reaped without a Disconnect.
    def seated_keys = @keys.to_a

    # :ok, :rate_limited past the subscribe bucket, :duplicate for a room this
    # connection is already in, or :too_many past the subscription cap. A
    # rate-limited or duplicate attempt does not consume a subscription slot.
    def admit_subscription(key, now)
      @seen_at = now
      return :rate_limited unless @subscribe.take(now)
      return :duplicate if @keys.include?(key)
      return :too_many if @keys.size >= @max_subscriptions

      @keys << key
      :ok
    end

    def release_subscription(key, now)
      @seen_at = now
      @keys.delete(key)
    end

    def take_frame(now)
      @seen_at = now
      @frames.take(now)
    end

    def frame_drops = @frames.drops

    def size = @keys.size
  end

  attr_reader :max_subscriptions, :max_age

  def initialize(max_subscriptions: Limits::MAX_SUBSCRIPTIONS_PER_CONNECTION,
                 max_age: Limits::CONNECTION_SLOT_TTL)
    @max_subscriptions = max_subscriptions
    @max_age = max_age
    @guards = {}
    @mutex = Mutex.new
  end

  # Record a connection's identity (its throttle IP and slot token) at connect,
  # so the sweep can free its connection slot if it leaks. Creates the guard
  # (every accepted connection gets one) and stamps it live.
  def register(connection_id, ip, slot_token, now = monotonic)
    @mutex.synchronize do
      g = guard(connection_id, now)
      g.ip = ip
      g.slot_token = slot_token
      g.seen_at = now
    end
    nil
  end

  def admit_subscription(connection_id, key, now = monotonic)
    @mutex.synchronize { guard(connection_id, now).admit_subscription(key, now) }
  end

  def release_subscription(connection_id, key, now = monotonic)
    @mutex.synchronize do
      g = @guards[connection_id]
      next unless g

      g.release_subscription(key, now)
      # Keep the guard while the socket is open even with no subscriptions: its
      # frame bucket must not reset just because it dropped to zero rooms. It is
      # dropped on disconnect, or reaped by the sweep.
    end
    nil
  end

  def take_frame(connection_id, now = monotonic)
    @mutex.synchronize { guard(connection_id, now).take_frame(now) }
  end

  def frame_drops(connection_id)
    @mutex.synchronize { @guards[connection_id]&.frame_drops || 0 }
  end

  def subscriptions(connection_id)
    @mutex.synchronize { @guards[connection_id]&.size || 0 }
  end

  # The Disconnect RPC fired (or the connection was rejected): drop its guard.
  def forget(connection_id)
    @mutex.synchronize { @guards.delete(connection_id) }
    nil
  end

  # Reap guards whose Disconnect never arrived, freeing each one's room seats and
  # connection slot. Returns the number reclaimed. The silent guards are removed
  # from the registry under the lock, then their seats and slots are released
  # OUTSIDE it: `rooms` and `limiter` take their own mutexes, and holding this
  # one across them would invite a lock-order deadlock. A removed guard is ours
  # alone, so reading its keys without the lock is safe.
  def sweep(now = monotonic, rooms: Rooms.current, limiter: ConnectionLimiter.current)
    dead = @mutex.synchronize do
      stale = @guards.select { |_id, g| now - g.seen_at >= @max_age }
      stale.each_key { |id| @guards.delete(id) }
      stale.values
    end
    dead.each { |g| reclaim(g, rooms, limiter) }
    Rails.logger.info("connection-guard: reclaimed #{dead.size} leaked connection(s)") if dead.any?
    dead.size
  end

  def count = @mutex.synchronize { @guards.size }

  private

  # Free a reaped connection's room seats and its connection slot. Called
  # without the guard-registry lock (see sweep).
  def reclaim(guard, rooms, limiter)
    guard.seated_keys.each { |key| rooms.leave(key) }
    limiter.release(guard.ip, guard.slot_token) if guard.ip && guard.slot_token
  end

  # Caller holds the mutex.
  def guard(connection_id, now)
    @guards[connection_id] ||= Guard.new(max_subscriptions: @max_subscriptions, now: now)
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
