# Concurrent WebSocket connections, counted per IP and process-wide.
#
# Rack::Attack throttles how fast an address can *open* connections. This caps
# how many it can *hold*, which is the resource that actually runs out: each open
# connection is a fiber, a socket, and an Action Cable connection object for as
# long as the client keeps it.
#
# Each slot carries the time it was acquired, for one reason: a leak. The count
# is decremented by `release`, which fires from the Disconnect RPC — and that
# RPC can fail to arrive (anycable-go drops a socket without delivering the
# disconnect, a partition, a crashed edge). A leaked slot would then sit
# elevated until the process restarts, slowly starving the leaking IP of its
# own future connections. `sweep` reaps slots older than CONNECTION_SLOT_TTL so
# a leak self-heals; the RoomSweeper thread calls it on its cadence, and
# `acquire` also drops an IP's own expired slots first, so a busy address heals
# without waiting for the sweep.
#
# Reaping can only *under*-count (free a slot a genuinely long-lived connection
# is still using), never over-count, so the worst case is the per-IP cap
# running slightly loose for a connection held past the TTL — never a wrongful
# rejection. That is the safe direction for a backstop.
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
    @slots = Hash.new { |h, k| h[k] = [] } # ip => [acquired_at (monotonic), ...]
    @total = 0
    @mutex = Mutex.new
  end

  # Returns :ok, :too_many_for_ip, or :too_many_connections. On :ok the caller
  # owns a slot and must call `release` when the connection closes.
  def acquire(ip, now = monotonic)
    @mutex.synchronize do
      drop_expired(ip, now)
      next :too_many_connections if @total >= @max_total
      next :too_many_for_ip if @slots[ip].size >= @max_per_ip

      @slots[ip] << now
      @total += 1
      :ok
    end
  end

  def release(ip)
    @mutex.synchronize do
      list = @slots[ip]
      next if list.empty?

      # Drop the oldest timestamp: identity doesn't matter for counting, and
      # keeping the fresher stamps makes the reaper more accurate.
      list.shift
      @total -= 1
      @slots.delete(ip) if list.empty?
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
    list = @slots[ip]
    return 0 if list.empty?

    kept = list.reject { |acquired_at| now - acquired_at >= @max_age }
    removed = list.size - kept.size
    return 0 if removed.zero?

    @total -= removed
    if kept.empty?
      @slots.delete(ip)
    else
      @slots[ip] = kept
    end
    removed
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
