module ApplicationCable
  # No authentication: rooms are anonymous and public. What the connection does
  # enforce is how many sockets one address may hold at once (layer 2 of the
  # throttle stack in config/limits.rb).
  #
  # The socket itself lives in anycable-go, not here. `connect` and `disconnect`
  # arrive as separate RPC calls with separate connection instances, so the
  # address a slot was taken for is kept as connection state rather than an
  # instance variable. Nil means this connection never took one, which is how a
  # rejected connect avoids releasing somebody else's slot.
  class Connection < ActionCable::Connection::Base
    identified_by :connection_id

    state_attr_accessor :client_ip

    def connect
      ip = request.remote_ip
      reject_unauthorized_connection unless ConnectionLimiter.current.acquire(ip) == :ok

      self.connection_id = SecureRandom.uuid
      self.client_ip = ip
    end

    def disconnect
      return if client_ip.blank?

      ConnectionLimiter.current.release(client_ip)
      self.client_ip = nil
    end
  end
end
