# Per-connection limits: what one WebSocket can do across all of its
# subscriptions.
#
# ConnectionLimiter limits how many sockets an address holds. This class limits
# what one open socket can do. It's keyed by connection, not subscription,
# because every problem it handles comes from one socket opening many
# subscriptions:
#
#   subscriptions   a hard count, so one socket can't subscribe to thousands
#                   of rooms. Each would take a seat and could create a
#                   document, going over the room cap.
#   subscribe rate  a token bucket on `subscribe` commands, so a socket can't
#                   cycle through rooms by subscribing and unsubscribing.
#   frames          one frame bucket for the whole connection. A bucket per
#                   subscription would reset on every subscribe and add up
#                   across subscriptions, so a socket could reset its burst by
#                   subscribing again or get N times the rate.
#   one seat/room   a connection holds at most one seat in a room, so it can't
#                   take every peer slot by itself.
#
# Guards are keyed by connection_id. ApplicationCable::Connection#connect
# creates it, and it's a connection identifier, so every command on a
# connection has the same string (channel tests have it too). The guard is
# removed on the Disconnect RPC. If that RPC never arrives, `sweep` removes it
# on the RoomSweeper's schedule.
#
# This class is also how the server knows a connection is still alive, and
# it's the only safe way to free the seats and slot of a connection that
# leaked. `seen_at` is updated on every frame the server sees, both document
# updates and awareness. The demo sends awareness through `send`, so it
# reaches Ruby. A tab that's open but idle still sends awareness:
# yrby-client repeats it on a heartbeat about every 15 seconds, well under the
# TTL. So a connection that's silent past CONNECTION_SLOT_TTL has leaked (its
# Disconnect RPC never arrived).
#
# The sweep then releases that connection's room seats, which frees the peer
# slot and removes the room from occupied_keys so the room sweeper can delete
# an abandoned room. It releases the connection slot and removes the guard.
# If the sweep removes a connection that's still open, the only effect is a
# looser limit. No one gets wrongly rejected. anycable-go's ANYCABLE_MAX_CONN
# is the hard limit under all of this.
class ConnectionGuard
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  # One connection's limits. It isn't serialized. Like the seats and the
  # connection slots, it lives in process memory, and every connection runs
  # through this one server.
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

    # A copy of the rooms this connection has seats in. The sweep releases
    # them when it removes a guard that never got a Disconnect.
    def seated_keys = @keys.to_a

    # Returns :ok, :rate_limited when the subscribe bucket is empty,
    # :duplicate for a room this connection is already in, or :too_many at the
    # subscription cap. A rate-limited or duplicate attempt doesn't use up a
    # subscription slot.
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

  # Records a connection's throttle IP and slot token at connect, so the sweep
  # can free its slot if it leaks. Every accepted connection gets a guard, and
  # this marks it as seen now.
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
      # Keep the guard while the socket is open, even with no subscriptions, so
      # its frame bucket doesn't reset when it leaves its last room. The guard
      # is removed on disconnect or by the sweep.
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

  # Called on the Disconnect RPC, or when the connection was rejected.
  def forget(connection_id)
    @mutex.synchronize { @guards.delete(connection_id) }
    nil
  end

  # Removes guards whose Disconnect never arrived and frees each one's room
  # seats and connection slot. Returns how many it removed.
  #
  # It takes the silent guards out of the registry under the lock, then
  # releases their seats and slots outside it. `rooms` and `limiter` take their
  # own mutexes, and holding this one while calling them could deadlock on lock
  # order. Once a guard is out of the registry nothing else can reach it, so
  # reading its keys without the lock is safe.
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

  # Frees a removed connection's room seats and connection slot. Called without
  # the registry lock (see sweep).
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
