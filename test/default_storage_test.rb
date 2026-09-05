# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require "logger"

# A channel that declares no storage hooks gets Y::Document storage — the
# Action Text posture: the gem's own tables are the default, and on_load /
# on_change remain the seam for pointing storage elsewhere.
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

  def test_declared_hooks_still_win
    klass = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| "custom" }
    end

    refute_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_load], klass.on_load
    assert_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_change], klass.on_change
  end

  def test_a_hookless_channel_records_and_serves_through_y_document
    channel = bare_channel
    channel.sync_subscribed("defaults/doc-1")

    frame = Y.wrap_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    channel.sync_receive({ "update" => Base64.strict_encode64(frame), "id" => 5 }, "defaults/doc-1")

    assert_includes channel.transmits, { "ack" => 5 }, "recorded through the default before acking"
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state("defaults/doc-1"))

    assert_equal 1, Y::Document.count
    refute_empty doc.read_text("content").to_s
  end
end
