# frozen_string_literal: true

require "action_cable"
require "y/action_cable"
require "puma"
require "concurrent/timer_task" # Action Cable's heartbeat; a Rails boot loads it
require "logger"

# A cable of its own for the city peers' tests: Puma serving Action Cable
# in this process, a room-keyed channel that records to a hash, and clients
# joined over real sockets. Everything between a peer and a person goes
# through the document.
module CityCable
  STORE = Hash.new { |hash, key| hash[key] = [] }
  STORE_LOCK = Mutex.new

  class Connection < ActionCable::Connection::Base
  end

  class RoomChannel < ActionCable::Channel::Base
    include Y::ActionCable

    on_load do |key|
      updates = STORE_LOCK.synchronize { STORE[key].dup }
      next if updates.empty?

      doc = Y::Doc.new
      updates.each { |update| doc.apply_update(update) }
      doc.encode_state_as_update
    end
    on_change { |key, update| STORE_LOCK.synchronize { STORE[key] << update } }

    def subscribed = sync_subscribed(params[:id])
    def receive(data) = sync_receive(data, params[:id])

    private

    def authorized?(_key) = true
  end

  def self.port
    @port ||= begin
      server = ActionCable.server
      server.config.cable = { "adapter" => "test" }
      server.config.logger = Logger.new(File::NULL)
      server.config.connection_class = -> { Connection }
      server.config.disable_request_forgery_protection = true
      puma = Puma::Server.new(server)
      listener = puma.add_tcp_listener("127.0.0.1", 0)
      puma.run
      Minitest.after_run { puma.stop(true) }
      listener.addr[1]
    end
  end

  def recorded(key) = STORE_LOCK.synchronize { STORE[key].size }

  def client
    client = Y::ActionCable::Client.new("ws://127.0.0.1:#{CityCable.port}/cable",
                                        channel: "CityCable::RoomChannel", params: { id: @key },
                                        root: nil, logger: Logger.new(File::NULL))
    (@clients ||= []) << client
    client
  end

  def close_clients = @clients&.each(&:unsubscribe)

  def read(client, name) = JSON.parse(client.doc.read_map(name) || "{}")

  # A person's presence, as the page sends it.
  def present(client, name: "Ada", pos: [0, 0])
    client.send_awareness(Y::Awareness.new.set_local_state(JSON.generate(user: { name: name, color: "#f00" },
                                                                         pos: { x: pos[0], y: pos[1] })))
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end
end
