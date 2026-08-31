module ApplicationCable
  # No authentication: rooms are anonymous and public. What the connection does
  # enforce is how many sockets one address may hold at once (layer 2 of the
  # throttle stack in app/lib/limits.rb).
  class Connection < ActionCable::Connection::Base
    identified_by :connection_id

    def connect
      @client_ip = request.remote_ip
      result = ConnectionLimiter.current.acquire(@client_ip)
      reject_unauthorized_connection unless result == :ok

      self.connection_id = SecureRandom.uuid
      @slot_held = true
    end

    def disconnect
      return unless @slot_held

      ConnectionLimiter.current.release(@client_ip)
      @slot_held = false
    end
  end
end
