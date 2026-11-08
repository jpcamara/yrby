# frozen_string_literal: true

# Y::AnyCable through anycable-core's RPC handler, the code anycable-go
# calls. Runs in the fixture's own bundle, apart from the main suite:
#
#   cd test/anycable && bundle exec ruby y_any_cable_test.rb
ENV["RAGE_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"
Dir.chdir(__dir__) # Rage.root is the working directory
require_relative "config/application"
require "minitest/autorun"

AnyCable.logger.level = Logger::WARN

class YAnyCableTest < Minitest::Test
  # Records broadcasts instead of sending them.
  class Recorder
    attr_reader :sent

    def initialize = @sent = []
    def broadcast(stream, payload) = @sent << [stream, JSON.parse(payload)]
  end

  def setup
    @broadcasts = Recorder.new
    AnyCable.broadcast_adapter = @broadcasts
    @room = "room-#{name}"
  end

  def env(query = "")
    AnyCable::Env.new(url: "ws://example.test/cable#{query}", headers: {})
  end

  def connect(query = "")
    AnyCable.rpc_handler.handle(:connect, AnyCable::ConnectionRequest.new(env: env(query)))
  end

  def identifier(id = @room, channel: "DocumentChannel")
    { channel: channel, id: id }.to_json
  end

  def command(name, identifier: identifier(), data: nil, identifiers: '{"user":null}', istate: {})
    request = AnyCable::CommandMessage.new(
      command: name, identifier: identifier, data: data.to_json,
      connection_identifiers: identifiers, env: AnyCable::Env.new(url: "ws://example.test/cable", istate: istate)
    )
    AnyCable.rpc_handler.handle(:command, request)
  end

  def update_frame(id = 1)
    doc = Y::Doc.new
    update = doc.edit { doc.get_text("body").push("hello") }
    { "update" => Base64.strict_encode64(Y.wrap_update(update)), "id" => id }
  end

  def messages(response) = response.transmissions.map { |t| JSON.parse(t) }

  def test_connect_welcomes_the_client_with_the_identifiers_from_identify
    response = connect("?user=alice")

    assert_equal :SUCCESS, response.status
    assert_equal({ "user" => "alice" }, JSON.parse(response.identifiers))
    assert_equal [{ "type" => "welcome" }], messages(response)
  end

  def test_identify_returning_nil_refuses_the_connection
    response = connect("?token=invalid")

    assert_equal :FAILURE, response.status
    assert_equal [{ "type" => "disconnect", "reason" => "unauthorized", "reconnect" => false }], messages(response)
  end

  def test_subscribe_streams_the_document_and_whispers_on_the_awareness_stream
    response = command("subscribe")

    assert_equal :SUCCESS, response.status
    assert_equal ["yrby:#{@room}", "yrby:#{@room}:awareness"], response.streams
    assert_equal({ "$w" => "yrby:#{@room}:awareness" }, response.env.istate.to_h)
    confirm, handshake = messages(response).partition { |m| m["type"] }

    assert_equal [{ "identifier" => identifier, "type" => "confirm_subscription" }], confirm
    assert_equal 1, handshake.size
    assert_equal Y::ActionCable::Sync::MSG_KIND_SYNC_STEP1,
                 Y.message_kind(Base64.strict_decode64(handshake.first.dig("message", "update")))
  end

  def test_an_unauthorized_key_is_rejected_without_streams
    response = command("subscribe", identifier: identifier("denied-1"))

    assert_equal :FAILURE, response.status
    assert_empty response.streams
    assert_equal [{ "identifier" => identifier("denied-1"), "type" => "reject_subscription" }], messages(response)
  end

  # The identifiers come with every command, from connect or from a JWT that
  # anycable-go verified.
  def test_authorized_sees_the_connection_identifiers
    private_doc = identifier("private-1")

    assert_equal :SUCCESS, command("subscribe", identifier: private_doc, identifiers: '{"user":"alice"}').status
    assert_equal :FAILURE, command("subscribe", identifier: private_doc, identifiers: '{"user":"bob"}').status
    assert_equal :FAILURE, command("subscribe", identifier: private_doc, identifiers: "").status
  end

  # A fresh channel handles the message, so the key comes from the
  # identifier's params, not from anything subscribe set.
  def test_receive_records_broadcasts_and_acks_an_update
    frame = update_frame(7)
    response = command("message", data: frame.merge("action" => "receive"))

    assert_equal :SUCCESS, response.status
    assert_equal [{ "identifier" => identifier, "message" => { "ack" => 7 } }], messages(response)
    assert_equal [["yrby:#{@room}", { "update" => frame["update"] }]], @broadcasts.sent
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state(@room))

    assert_equal "hello", doc.read_text("body")
  end

  def test_a_message_without_an_action_goes_to_receive
    assert_equal :SUCCESS, command("message", data: update_frame).status
    assert_equal 1, @broadcasts.sent.size
  end

  # Only subscribed, unsubscribed, and receive are reachable from a client.
  def test_a_client_cannot_call_the_sync_methods_or_other_helpers
    %w[sync_subscribed sync_receive sync_broadcast authorized? transmit stream_from whispers_to
       unsubscribed subscribed].each do |action|
      response = command("message", data: update_frame.merge("action" => action, "key" => "other"))

      assert_equal :FAILURE, response.status, action
      assert_empty response.transmissions, action
      assert_empty response.streams, action
    end
    assert_empty @broadcasts.sent
    assert_nil Y::Document.load_state(@room)
  end

  def test_the_sync_methods_and_transport_helpers_are_private
    %i[sync_subscribed sync_receive sync_broadcast sync_logger authorized? identifiers transmit
       stream_from reject logger].each do |method|
      assert DocumentChannel.private_method_defined?(method), "#{method} is private"
    end
  end

  def test_unsubscribe_calls_unsubscribed_and_stops_the_streams
    log = capture_log { @response = command("unsubscribe", istate: { "$w" => "yrby:#{@room}:awareness" }) }

    assert_equal :SUCCESS, @response.status
    assert @response.stop_streams
    assert_equal({ "$w" => "" }, @response.env.istate.to_h)
    assert_match(/unsubscribed #{@room}/, log)
  end

  def test_disconnect_unsubscribes_each_subscription
    request = AnyCable::DisconnectRequest.new(
      identifiers: '{"user":"alice"}', subscriptions: [identifier("a"), identifier("b")], env: env
    )
    log = capture_log { @response = AnyCable.rpc_handler.handle(:disconnect, request) }

    assert_equal :SUCCESS, @response.status
    assert_match(/unsubscribed a.*unsubscribed b/m, log)
  end

  def test_an_unknown_or_non_sync_channel_is_refused
    assert_equal :FAILURE, command("subscribe", identifier: identifier(channel: "Nope")).status
    assert_equal :FAILURE, command("subscribe", identifier: identifier(channel: "Object")).status
    assert_equal :FAILURE, command("subscribe", identifier: identifier(channel: "Y::AnyCable::Channel")).status
  end

  def test_storage_defaults_to_y_document
    assert_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_load], DocumentChannel.on_load
    assert_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_change], DocumentChannel.on_change
    refute defined?(Yrby::Engine)
  end

  def test_broadcast_sends_a_ruby_side_update_to_the_document_stream
    doc = Y::Doc.new
    update = doc.edit { doc.get_text("body").push("from ruby") }

    Y::AnyCable.broadcast("doc", update)

    assert_equal [["yrby:doc", { "update" => Base64.strict_encode64(Y.wrap_update(update)) }]], @broadcasts.sent
  end

  private

  def capture_log
    io = StringIO.new
    previous = AnyCable.logger
    AnyCable.logger = Logger.new(io)
    yield
    io.string
  ensure
    AnyCable.logger = previous
  end
end
