require "test_helper"

# Action Cable lets a client call any public method a channel adds, by
# sending {"action": name}. These tests check that receive is the only one on
# this site's channels, with the yrby-rails and lexxy-realtime versions in
# Gemfile.lock.
class PublicActionBypassTest < ActionCable::Channel::TestCase
  tests RoomChannel

  CHANNELS = [Y::DocumentChannel, LexxyRealtime::DocumentChannel, RoomChannel, LexxyChannel].freeze

  setup do
    stub_connection(connection_id: "c1")
    @room = Room.create!(slug: "room1")
    connection.define_singleton_method(:close) { |**| nil }
  end

  def document = @room.collaborative_document(:tiptap)
  def step1 = Base64.strict_encode64(Y::Doc.new.sync_step1)
  def acks = transmissions.filter_map { |m| m["ack"] }

  test "receive is the only action a client can call" do
    CHANNELS.each do |channel|
      assert_equal Set["receive"], channel.action_methods, channel.name
    end
  end

  # 500 handshakes through receive hit the frame bucket (burst 120). Direct
  # sync_subscribed calls would each load the document, answer, and add a
  # stream without touching the bucket, so they must be refused.
  test "a client cannot call sync_subscribed to skip the frame bucket" do
    subscribe grant: document.grant, name: "tiptap"
    base = transmissions.size
    500.times { perform :receive, "update" => step1 }
    via_receive = transmissions.size - base

    ConnectionGuard.current = ConnectionGuard.new
    streams = subscription.streams.dup
    base = transmissions.size
    500.times { |i| perform :sync_subscribed, "n" => i }

    assert_operator via_receive, :<, 500
    assert_equal 0, transmissions.size - base
    assert_equal streams, subscription.streams
  end

  test "a client cannot give its seat back and stay subscribed" do
    subscribe grant: document.grant, name: "tiptap"
    perform :unsubscribed

    assert_equal 1, Rooms.current.peers(@room, "tiptap")
  end

  test "a client cannot run subscribed again" do
    subscribe grant: document.grant, name: "tiptap"
    streams = subscription.streams.dup
    base = transmissions.size
    perform :subscribed

    assert_equal streams, subscription.streams
    assert_equal base, transmissions.size
  end

  test "a client cannot set the authorized key or seat state" do
    subscribe grant: document.grant, name: "tiptap"
    perform :authorized_document_key=, "key" => "other"
    perform :seat=, "x" => 1
    perform :notified=, "x" => 1
    perform :sync_receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert_equal document.key, subscription.send(:authorized_document_key)
    assert subscription.send(:seat)
    assert_nil subscription.send(:notified)
    assert_empty acks
  end

  test "subscribe, receive, and unsubscribe still work" do
    subscribe grant: document.grant, name: "tiptap"

    assert_predicate subscription, :confirmed?
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert_equal [1], acks
    unsubscribe

    assert_equal 0, Rooms.current.peers(@room, "tiptap")
  end
end
