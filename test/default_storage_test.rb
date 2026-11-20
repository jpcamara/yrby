# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require "logger"

# A channel that declares no storage hooks stores through Y::Document.
# Declaring on_load and on_change switches it to a different store.
class DefaultStorageTest < Minitest::Test
  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
  end

  def bare_channel
    klass = Class.new do
      include Y::ActionCable::Sync

      attr_accessor :transmits, :streams, :logger

      def transmit(data) = transmits << data
      def reject = nil

      def stream_from(name, **opts, &)
        streams << [name, opts]
      end

      def authorized?(_key) = true

      define_method(:sync_distribute) { |_encoded| nil }
    end
    helper = klass.new
    helper.transmits = []
    helper.streams = []
    helper.logger = Logger.new(File::NULL)
    helper
  end

  def test_hooks_default_to_y_document_storage
    klass = Class.new { include Y::ActionCable::Sync }

    assert_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_load], klass.on_load
    assert_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_change], klass.on_change
  end

  def test_the_default_answers_the_handshake_from_the_stored_rows
    Y::Document.append("room", YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    Y::Document.find_by(key: "room").compact!
    Y::Document.append("room", YjsFixtures::TwoDocsMerged::DOC2_UPDATE)
    channel = bare_channel
    client = Y::Doc.new

    Y::Document.stub(:load_parts, ->(*) { flunk "loaded the document" }) do
      channel.send(:sync_subscribed, "room")
      channel.send(:sync_receive, { "update" => Base64.strict_encode64(client.sync_step1) }, "room")
    end
    frames = channel.transmits.map { |t| Base64.strict_decode64(t["update"]) }
    frames.drop(1).each { |f| client.handle_sync_message(f) }

    assert_equal Y::Document.sync_state("room"), frames.first.byteslice(3..),
                 "SyncStep1 carries the stored state vector"
    assert_equal "from doc1from doc2", client.read_text("content")
  end

  def test_declaring_storage_drops_the_default_handshake
    klass = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| nil }
      on_change { |_key, _update| nil }
    end

    assert_nil klass.on_sync_state
    assert_nil klass.on_sync_diff
  end

  def test_one_declared_hook_raises_before_subscribing_or_acking
    %i[on_load on_change].each do |hook|
      channel = bare_channel
      channel.class.public_send(hook) { |*| nil }

      error = assert_raises(Y::Error) { channel.send(:sync_subscribed, "partial") }
      assert_match(hook == :on_load ? /on_change/ : /on_load/, error.message)
      assert_empty channel.streams
      assert_empty channel.transmits

      frame = Base64.strict_encode64(Y.wrap_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE))
      assert_raises(Y::Error) { channel.send(:sync_receive, { "update" => frame, "id" => 1 }, "partial") }
      assert_empty channel.transmits
      assert_equal 0, Y::DocumentUpdate.count
    end
  end

  def test_subclasses_inherit_explicit_hooks_without_mixing_in_defaults
    parent = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| "custom" }
    end
    child = Class.new(parent)

    assert_nil child.on_change
    child.on_change { |_key, _update| nil }

    assert_equal parent.on_load, child.on_load
    refute_nil child.on_change
    assert_nil parent.on_change

    grandchild = Class.new(child)
    grandchild.on_load { |_key| "override" }

    assert_equal child.on_change, grandchild.on_change
    refute_equal child.on_load, grandchild.on_load
  end

  def test_a_declared_hook_replaces_the_default
    klass = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| "custom" }
    end

    refute_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_load], klass.on_load
    assert_nil klass.on_change, "a custom loader must not get paired with the default recorder"
  end

  def test_a_hookless_channel_records_and_serves_through_y_document
    channel = bare_channel
    channel.send(:sync_subscribed, "defaults/doc-1")

    frame = Y.wrap_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    channel.send(:sync_receive, { "update" => Base64.strict_encode64(frame), "id" => 5 }, "defaults/doc-1")

    assert_includes channel.transmits, { "ack" => 5 }, "the default store recorded the update before the ack"
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state("defaults/doc-1"))

    assert_equal 1, Y::Document.count
    refute_empty doc.read_text("content").to_s
  end
end
