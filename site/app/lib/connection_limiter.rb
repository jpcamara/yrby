# Counts open WebSocket connections per IP and for the whole process.
#
# Rack::Attack limits how fast an address can open connections. This limits
# how many it can keep open, which is the resource that actually runs out.
# Each open connection uses a fiber, a socket, and an Action Cable connection
# object for as long as the client keeps it.
#
# `acquire` gives each slot a token, and `release` frees the slot for that
# token. `disconnect` has to release the slot its own `connect` took. If it
# released some other slot for the same IP, the count would drift from the
# real number of sockets and go past both caps.
#
# This class only counts. It doesn't decide when a slot is stale. `release`
# frees a slot when the Disconnect RPC arrives. If that RPC never arrives, the
# ConnectionGuard sweep frees the slot's token based on when the server last
# saw a frame from it. Age alone isn't used. Expiring old slots would cut off
# connections that are still open, like someone reading a long document.
#
# The real limit on sockets is ANYCABLE_MAX_CONN on the Go process, which
# holds the sockets. This class adds a per-IP cap and a softer process-wide
# cap in front of it.
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
    @slots = Hash.new { |h, k| h[k] = {} } # ip => { token => true }
    @total = 0
    @mutex = Mutex.new
  end

  # Returns [:ok, token], [:too_many_for_ip, nil], or
  # [:too_many_connections, nil]. On :ok the caller holds the slot for `token`
  # and must call `release(ip, token)` when the connection closes.
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

  # Releases the slot `acquire` returned. A token that isn't held does nothing.
  # That covers a slot the sweep already freed and a second disconnect, so the
  # count can't go negative or free another connection's slot.
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
