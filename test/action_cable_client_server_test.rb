# frozen_string_literal: true

require "test_helper"
require "action_cable"
require "y/action_cable"
require "y/action_cable/client"
require "puma"
require "concurrent/timer_task" # Action Cable's heartbeat; a Rails boot loads it
require "logger"

# The client against a real cable: Puma serving Action Cable in this
# process, a room-keyed channel that records to a hash, and clients on
# sockets of their own. What one client sends the server records, acks,
# and distributes to the other.
class ActionCableClientServerTest < Minitest::Test
  STORE = Hash.new { |hash, key| hash[key] = [] }
  STORE_LOCK = Mutex.new

  class Connection < ActionCable::Connection::Base
  end

  # The demo's channel: public rooms named by `id`.
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

    def authorized?(key) = !key.start_with?("private")
  end

  # One server for the whole run.
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

  def setup
    @key = "room-#{rand(1 << 32)}"
    @clients = []
  end

  def teardown
    @clients.each(&:unsubscribe)
  end

  def client(key = @key)
    client = Y::ActionCable::Client.new("ws://127.0.0.1:#{self.class.port}/cable",
                                        channel: "ActionCableClientServerTest::RoomChannel", params: { id: key },
                                        logger: Logger.new(File::NULL))
    @clients << client
    client
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def test_an_update_is_recorded_acked_and_delivered_to_another_client
    writer = client.subscribe
    seen = Queue.new
    reader = client.on_update { |update, doc, changed| seen << [update, doc.read_xml("root"), changed] }.subscribe

    assert_predicate writer, :synced?
    update = writer.doc.diff { |d| Y::Lexical.append_paragraph(d, "sent over the socket") }
    writer.send_update(update)

    wait_until { !writer.pending? }

    assert_equal [update], STORE_LOCK.synchronize { STORE[@key].dup }, "the server recorded it before acking"
    assert_equal [update, "sent over the socket", [0]], seen.pop(timeout: 5)
    assert_equal "sent over the socket", reader.doc.read_xml("root")
  end

  def test_a_document_already_in_the_store_arrives_with_the_handshake
    STORE_LOCK.synchronize { STORE[@key] << Y::Doc.new.diff { |d| Y::Lexical.append_paragraph(d, "before") } }
    joined = client.subscribe

    assert_equal "before", joined.doc.read_xml("root")
  end

  def test_presence_reaches_the_other_client
    first = client.subscribe
    seen = Queue.new
    client.on_awareness { |frame| seen << frame }.subscribe
    frame = Y::Awareness.new.set_local_state(JSON.generate(name: "Agent"))
    first.send_awareness(frame)

    assert_equal frame, seen.pop(timeout: 5)
  end

  def test_a_rejected_subscription_raises
    error = assert_raises(Y::Error) { client("private-room").subscribe(timeout: 5) }

    assert_match(/rejected/, error.message)
  end

  # Inside a reactor the client is a task of the caller's, so a Sync block
  # waits for it: leave before the block ends.
  def test_the_client_runs_as_a_task_inside_a_reactor
    text = nil
    Sync do
      inside = client.subscribe
      inside.send_update(inside.doc.diff { |d| Y::Lexical.append_paragraph(d, "from a fiber") })
      wait_until { !inside.pending? }
      text = Y::Doc.new.tap { |d| STORE[@key].each { |u| d.apply_update(u) } }.read_xml("root")
      inside.unsubscribe
    end

    assert_equal "from a fiber", text
  end
end
