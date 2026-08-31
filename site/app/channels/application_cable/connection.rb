module ApplicationCable
  # No authentication: rooms are anonymous and public. What the connection does
  # enforce is how many sockets one address may hold at once (layer 2 of the
  # throttle stack in config/limits.rb).
  #
  # The socket itself lives in anycable-go, not here. `connect` and `disconnect`
  # arrive as separate RPC calls with separate connection instances, so the
  # address a slot was taken for AND the slot's token are kept as connection
  # state rather than instance variables. Nil means this connection never took a
  # slot, which is how a rejected connect avoids releasing somebody else's.
  class Connection < ActionCable::Connection::Base
    identified_by :connection_id

    state_attr_accessor :client_ip, :slot_token

    def connect
      ip = client_ip!
      status, token = ConnectionLimiter.current.acquire(ip)
      reject_unauthorized_connection unless status == :ok

      self.connection_id = SecureRandom.uuid
      self.client_ip = ip
      self.slot_token = token
    end

    def disconnect
      ConnectionGuard.current.forget(connection_id) if connection_id
      return if client_ip.blank?

      ConnectionLimiter.current.release(client_ip, slot_token)
      self.client_ip = nil
      self.slot_token = nil
    end

    private

    # The real client address, derived with the app's trusted-proxy set — NOT
    # `request.remote_ip`.
    #
    # On the AnyCable connect path the request env is built by the RPC handler,
    # not by the Rack middleware stack, so ActionDispatch::RemoteIp never runs
    # and `request.remote_ip` falls back to Rack's default IP logic — which
    # trusts every private range, including 192.168/16. That is exactly the range
    # trusted_proxies deliberately excludes (the Pi's LAN), so on Rack's defaults
    # a LAN client could forge an X-Forwarded-For and land as any address it
    # likes, defeating the per-IP cap. Re-deriving here with TrustedProxies::
    # RANGES applies the same rule the HTTP layer uses: a forwarded IP is only
    # honored past a hop we actually trust, otherwise the socket's own address
    # (REMOTE_ADDR, set by anycable-go from the real peer) wins.
    def client_ip!
      TrustedProxies.client_ip(request)
    end
  end
end
