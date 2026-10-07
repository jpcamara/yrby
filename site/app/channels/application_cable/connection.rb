module ApplicationCable
  # Rooms are anonymous and public, so there's no authentication. The
  # connection only limits how many sockets one address can hold at once
  # (layer 2 of the throttles in config/limits.rb).
  #
  # The socket lives in anycable-go. `connect` and `disconnect` arrive as
  # separate RPC calls on separate connection instances, so the client address
  # and the slot token are stored as connection state. Instance variables
  # wouldn't survive between the two calls. A nil address means this connection
  # never took a slot, so a rejected connect doesn't release someone else's.
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
      # Register with the guard now. If the Disconnect RPC never arrives, the
      # guard's liveness sweep can still free this slot and any room seats.
      # See ConnectionGuard.
      ConnectionGuard.current.register(connection_id, ip, token)
    end

    def disconnect
      ConnectionGuard.current.forget(connection_id) if connection_id
      return if client_ip.blank?

      ConnectionLimiter.current.release(client_ip, slot_token)
      self.client_ip = nil
      self.slot_token = nil
    end

    private

    # The real client address, worked out with the app's trusted proxies.
    # Don't use `request.remote_ip` here.
    #
    # On the AnyCable connect path, the RPC handler builds the request env and
    # the Rack middleware stack never runs. ActionDispatch::RemoteIp is skipped,
    # and `request.remote_ip` falls back to Rack's default, which trusts every
    # private range including 192.168/16. TrustedProxies leaves that range out
    # on purpose, because it's a home or office LAN. With Rack's default, a
    # client on that LAN could send a forged X-Forwarded-For, pick any address,
    # and get around the per-IP cap. TrustedProxies.client_ip applies the same
    # rule as the HTTP layer. It only accepts a forwarded IP behind a proxy we
    # trust. Otherwise it uses REMOTE_ADDR, which anycable-go sets from the
    # real peer.
    def client_ip!
      TrustedProxies.client_ip(request)
    end
  end
end
