# Concurrent WebSocket connections, counted per IP and process-wide.
#
# Rack::Attack throttles how fast an address can *open* connections. This caps
# how many it can *hold*, which is the resource that actually runs out: each open
# connection is a fiber, a socket, and an Action Cable connection object for as
# long as the client keeps it.
class ConnectionLimiter
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  attr_reader :max_per_ip, :max_total

  def initialize(max_per_ip: Limits::MAX_CONNECTIONS_PER_IP, max_total: Limits::MAX_CONNECTIONS)
    @max_per_ip = max_per_ip
    @max_total = max_total
    @per_ip = Hash.new(0)
    @total = 0
    @mutex = Mutex.new
  end

  # Returns :ok, :too_many_for_ip, or :too_many_connections. On :ok the caller
  # owns a slot and must call `release` when the connection closes.
  def acquire(ip)
    @mutex.synchronize do
      next :too_many_connections if @total >= @max_total
      next :too_many_for_ip if @per_ip[ip] >= @max_per_ip

      @per_ip[ip] += 1
      @total += 1
      :ok
    end
  end

  def release(ip)
    @mutex.synchronize do
      next unless @per_ip.key?(ip)

      @per_ip[ip] -= 1
      @per_ip.delete(ip) if @per_ip[ip] <= 0
      @total -= 1 if @total.positive?
    end
    nil
  end

  def count(ip) = @mutex.synchronize { @per_ip[ip] }

  def total = @mutex.synchronize { @total }
end
