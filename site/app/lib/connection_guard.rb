# Per-connection limits: what one WebSocket can do across all of its
# subscriptions.
#
# ConnectionLimiter limits how many sockets an address holds. This class limits
# how fast one open socket can act:
#
#   subscribe rate  a token bucket on `subscribe` commands, so a socket can't
#                   cycle through rooms by subscribing and unsubscribing.
#   frames          one frame bucket for the whole connection. A bucket per
#                   subscription would reset on every subscribe and add up
#                   across subscriptions, so a socket could reset its burst by
#                   subscribing again or get N times the rate.
#
# How many documents a connection is in, and that it holds at most one seat
# in each, are Seat rows (see Rooms#join), shared by every server process.
# These buckets live in process memory. A connection's commands can reach
# any Falcon process, and each one keeps its own buckets for it, so with N
# processes a socket gets up to N times these rates.
#
# Guards are keyed by connection_id. ApplicationCable::Connection#connect
# creates it, and it's a connection identifier, so every command on a
# connection has the same string (channel tests have it too). The guard is
# removed on the Disconnect RPC. If that RPC never arrives, or reaches another
# process, `sweep` removes it on the RoomSweeper's schedule.
#
# This class is also how a process knows a connection is still alive.
# `seen_at` is updated on every frame the process sees, both document updates
# and awareness. The demo sends awareness through `send`, so it reaches Ruby.
# A tab that's open but idle still sends awareness: yrby-client repeats it on
# a heartbeat about every 15 seconds, well under the TTL. So a connection
# that's silent past CONNECTION_SLOT_TTL has leaked here, and the sweep frees
# the connection slot this process gave it. Seats have their own clock
# (Seat#seen_at), which `seat_touch_due?` paces. If the sweep removes a
# connection that's still open, the only effect is a looser limit. No one
# gets wrongly rejected. anycable-go's ANYCABLE_MAX_CONN is the hard limit
# under all of this.
class ConnectionGuard
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  # One connection's limits in this process. It isn't serialized.
  class Guard
    attr_accessor :seen_at, :ip, :slot_token

    def initialize(now:)
      @subscribe = TokenBucket.new(capacity: Limits::SUBSCRIBE_BURST,
                                   refill_per_second: Limits::SUBSCRIBES_PER_SECOND, now: now)
      @frames = TokenBucket.new(capacity: Limits::FRAME_BURST,
                                refill_per_second: Limits::FRAMES_PER_SECOND, now: now)
      @seen_at = now
      @seats_touched_at = nil
    end

    # False when the subscribe bucket is empty.
    def admit_subscription(now)
      @seen_at = now
      @subscribe.take(now)
    end

    def take_frame(now)
      @seen_at = now
      @frames.take(now)
    end

    # True at most once every SEAT_TOUCH_INTERVAL.
    def seat_touch_due?(now)
      return false if @seats_touched_at && now - @seats_touched_at < Limits::SEAT_TOUCH_INTERVAL

      @seats_touched_at = now
      true
    end

    def frame_drops = @frames.drops
  end

  attr_reader :max_age

  def initialize(max_age: Limits::CONNECTION_SLOT_TTL)
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

  # False when the connection is subscribing too fast.
  def admit_subscription(connection_id, now = monotonic)
    @mutex.synchronize { guard(connection_id, now).admit_subscription(now) }
  end

  def take_frame(connection_id, now = monotonic)
    @mutex.synchronize { guard(connection_id, now).take_frame(now) }
  end

  # Whether this process should refresh the connection's seats now (see Seat).
  # Each process paces its own refreshes, so with N processes a connection's
  # seats are refreshed up to N times per interval.
  def seat_touch_due?(connection_id, now = monotonic)
    @mutex.synchronize { guard(connection_id, now).seat_touch_due?(now) }
  end

  def frame_drops(connection_id)
    @mutex.synchronize { @guards[connection_id]&.frame_drops || 0 }
  end

  # Called on the Disconnect RPC, or when the connection was rejected.
  def forget(connection_id)
    @mutex.synchronize { @guards.delete(connection_id) }
    nil
  end

  # Removes guards this process hasn't heard from past the TTL and frees each
  # one's connection slot. Returns how many it removed.
  #
  # It takes the silent guards out of the registry under the lock, then
  # releases their slots outside it. The limiter takes its own mutex, and
  # holding this one while calling it could deadlock on lock order.
  def sweep(now = monotonic, limiter: ConnectionLimiter.current)
    dead = @mutex.synchronize do
      stale = @guards.select { |_id, g| now - g.seen_at >= @max_age }
      stale.each_key { |id| @guards.delete(id) }
      stale.values
    end
    dead.each { |g| limiter.release(g.ip, g.slot_token) if g.ip && g.slot_token }
    Rails.logger.info("connection-guard: reclaimed #{dead.size} leaked connection(s)") if dead.any?
    dead.size
  end

  def count = @mutex.synchronize { @guards.size }

  private

  # Caller holds the mutex.
  def guard(connection_id, now)
    @guards[connection_id] ||= Guard.new(now: now)
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
