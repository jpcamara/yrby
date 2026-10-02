# Concurrent WebSocket connections, counted per IP and process-wide.
#
# Rack::Attack throttles how fast an address can *open* connections. This caps
# how many it can *hold*, which is the resource that actually runs out: each open
# connection is a fiber, a socket, and an Action Cable connection object for as
# long as the client keeps it.
#
# Each slot has a token, minted by `acquire` and released by that exact token.
# Identity matters: `disconnect` releases the slot its own `connect` took, not
# "the oldest one for this IP", without the token, releasing the wrong slot
# lets the running count drift away from the real socket count, past both caps.
#
# This is a pure token ledger: it counts, it does not decide when a slot is
# stale. A slot is freed by `release` (from the Disconnect RPC) or, when that RPC
# never arrives, by the ConnectionGuard sweep, which reaps a connection by
# LIVENESS, the last server-visible frame, and releases the exact slot token.
# Age is deliberately not a signal here: expiring a slot purely because it is old
# would reap a connection that is genuinely still open (a long reader), which is
# the leak the guard's liveness clock avoids.
#
# The real ceiling on sockets is ANYCABLE_MAX_CONN on the Go process, which owns
# them; this limiter is the per-IP and soft process-wide cap in front of it.
class ConnectionLimiter
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  attr_reader :max_per_ip, :max_total

  def initialize(max_per_ip: Limits::MAX_CONNECTIONS_PER_IP,
                 max_total: Limits::MAX_CONNECTIONS)
    @max_per_ip = max_per_ip
    @max_total = max_total
    @slots = Hash.new { |h, k| h[k] = {} } # ip => Set of tokens
    @total = 0
    @mutex = Mutex.new
  end

  # Returns [:ok, token], [:too_many_for_ip, nil], or [:too_many_connections,
  # nil]. On :ok the caller owns the slot named by `token` and must call
  # `release(ip, token)` when the connection closes.
  def acquire(ip)
    @mutex.synchronize do
      next [:too_many_connections, nil] if @total >= @max_total
      next [:too_many_for_ip, nil] if @slots[ip].size >= @max_per_ip

      token = SecureRandom.uuid
      @slots[ip][token] = true
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

  def count(ip)
    @mutex.synchronize { @slots[ip].size }
  end

  def total = @mutex.synchronize { @total }
end
