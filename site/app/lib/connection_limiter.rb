# Concurrent WebSocket connections, counted per IP and process-wide.
#
# Rack::Attack throttles how fast an address can *open* connections. This caps
# how many it can *hold*, which is the resource that actually runs out: each open
# connection is a fiber, a socket, and an Action Cable connection object for as
# long as the client keeps it.
#
# Each slot has a token, minted by `acquire` and released by that exact token.
# Identity matters: `disconnect` releases the slot its own `connect` took, not
# "the oldest one for this IP" — without the token, releasing the wrong slot
# lets the running count drift away from the real socket count, past both caps.
#
# A slot also carries the time it was acquired, for one reason: a leak. The
# count is decremented by `release`, which fires from the Disconnect RPC — and
# that RPC can fail to arrive (anycable-go drops a socket without delivering the
# disconnect, a partition, a crashed edge). A leaked slot would then sit elevated
# until the process restarts. `sweep` reaps slots older than CONNECTION_SLOT_TTL
# so a leak self-heals; the RoomSweeper thread calls it on its cadence, and
# `acquire` also drops an IP's own expired slots first, so a busy address heals
# without waiting for the sweep. The TTL is only a leak backstop — a genuine demo
# session is far shorter than an hour, so a live connection is rarely reaped —
# and it can only *under*-count (free a slot a long-lived connection still uses),
# never over-count, so the worst case is the per-IP cap running slightly loose,
# never a wrongful rejection.
#
# The real ceiling on sockets is ANYCABLE_MAX_CONN on the Go process, which owns
# them; this limiter is the per-IP and soft process-wide cap in front of it.
class ConnectionLimiter
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  attr_reader :max_per_ip, :max_total, :max_age

  def initialize(max_per_ip: Limits::MAX_CONNECTIONS_PER_IP,
                 max_total: Limits::MAX_CONNECTIONS,
                 max_age: Limits::CONNECTION_SLOT_TTL)
    @max_per_ip = max_per_ip
    @max_total = max_total
    @max_age = max_age
    @slots = Hash.new { |h, k| h[k] = {} } # ip => { token => acquired_at (monotonic) }
    @total = 0
    @mutex = Mutex.new
  end

  # Returns [:ok, token], [:too_many_for_ip, nil], or [:too_many_connections,
  # nil]. On :ok the caller owns the slot named by `token` and must call
  # `release(ip, token)` when the connection closes.
  def acquire(ip, now = monotonic)
    @mutex.synchronize do
      drop_expired(ip, now)
      next [:too_many_connections, nil] if @total >= @max_total
      next [:too_many_for_ip, nil] if @slots[ip].size >= @max_per_ip

      token = SecureRandom.uuid
      @slots[ip][token] = now
      @total += 1
      [:ok, token]
    end
  end

  # Release the exact slot `acquire` handed out. A token that isn't held (already
  # reaped as leaked, or a double disconnect) is a no-op, so the count can't go
  # negative or free a slot that belongs to another live connection.
  def release(ip, token)
    @mutex.synchronize do
      slots = @slots[ip]
      next unless slots.delete(token)

      @total -= 1
      @slots.delete(ip) if slots.empty?
    end
    nil
  end

  # Reap every IP's expired slots. Returns the number reclaimed.
  def sweep(now = monotonic)
    @mutex.synchronize do
      reclaimed = @slots.keys.sum { |ip| drop_expired(ip, now) }
      Rails.logger.info("connection-limiter: reclaimed #{reclaimed} leaked slot(s)") if reclaimed.positive?
      reclaimed
    end
  end

  def count(ip, now = monotonic)
    @mutex.synchronize do
      drop_expired(ip, now)
      @slots[ip].size
    end
  end

  def total = @mutex.synchronize { @total }

  private

  # Caller holds the mutex. Removes ip's slots older than max_age, adjusts the
  # running total, and prunes an emptied IP. Returns the count removed.
  def drop_expired(ip, now)
    slots = @slots[ip]
    return 0 if slots.empty?

    expired = slots.select { |_token, acquired_at| now - acquired_at >= @max_age }
    return 0 if expired.empty?

    expired.each_key { |token| slots.delete(token) }
    @total -= expired.size
    @slots.delete(ip) if slots.empty?
    expired.size
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
