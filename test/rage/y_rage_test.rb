# frozen_string_literal: true

# Y::Rage against real Rage. Runs in the fixture's own bundle, apart from the
# main suite:
#
#   cd test/rage && bundle exec ruby y_rage_test.rb
ENV["RAGE_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"
Dir.chdir(__dir__) # Rage.root is the working directory
require_relative "config/application"
require "minitest/autorun"

class YRageTest < Minitest::Test
  def channel = DocumentChannel.new(nil, { id: "doc" }, nil)

  # Swaps Rage.cable.broadcast for a recorder for the block's duration.
  def capture_broadcasts
    sent = []
    cable = Rage.cable.singleton_class
    cable.alias_method(:real_broadcast, :broadcast)
    cable.define_method(:broadcast) { |stream, data| sent << [stream, data] }
    yield
    sent
  ensure
    cable.alias_method(:broadcast, :real_broadcast)
    cable.remove_method(:real_broadcast)
  end

  def test_a_rage_channel_gets_the_sync_api
    assert_operator DocumentChannel, :<, Y::ActionCable::Sync
    assert_operator DocumentChannel, :<, Y::Rage
    assert DocumentChannel.instance_method(:sync_subscribed)
    assert DocumentChannel.instance_method(:sync_receive)
  end

  # yrby-rails requires y/rage when Rage is loaded, and y/rage loads the
  # models, so the hooks default to Y::Document with no Rails engine.
  def test_storage_defaults_to_y_document
    assert_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_load], DocumentChannel.on_load
    assert_equal Y::ActionCable::Sync::DEFAULT_STORAGE[:on_change], DocumentChannel.on_change
    refute defined?(Yrby::Engine)
  end

  def test_relays_broadcast_through_rage_cable
    sent = capture_broadcasts { channel.send(:sync_broadcast, "yrby:doc", { "update" => "AA==" }) }

    assert_equal [["yrby:doc", { "update" => "AA==" }]], sent
  end

  def test_logs_go_to_the_rage_logger
    assert_same Rage.logger, channel.send(:sync_logger)
  end

  # Private, so Rage doesn't register them as actions a client can call.
  def test_the_rage_overrides_are_private
    assert DocumentChannel.private_method_defined?(:sync_broadcast)
    assert DocumentChannel.private_method_defined?(:sync_logger)
  end

  def test_broadcast_sends_a_ruby_side_update_to_the_document_stream
    doc = Y::Doc.new
    update = doc.edit { doc.get_text("body").push("from ruby") }

    sent = capture_broadcasts { Y::Rage.broadcast("doc", update) }

    assert_equal [["yrby:doc", { "update" => Base64.strict_encode64(Y.wrap_update(update)) }]], sent
  end
end
