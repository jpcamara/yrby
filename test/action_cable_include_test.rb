# frozen_string_literal: true

require "test_helper"
require "y/action_cable"

# `include Y::ActionCable` and `include Y::ActionCable::Sync` are the same
# integration; the namespace module forwards to Sync so the channel include
# doesn't need the suffix.
class ActionCableIncludeTest < Minitest::Test
  def test_including_the_namespace_module_is_the_sync_concern
    channel = Class.new do
      include Y::ActionCable

      on_load { |_key| nil }
      on_change { |_key, _update| nil }
    end

    assert_operator channel, :<, Y::ActionCable::Sync
    assert_respond_to channel, :on_load
    assert_respond_to channel, :max_frame_bytes
    assert channel.instance_method(:sync_receive), "instance API present"
  end

  def test_the_long_spelling_still_works
    channel = Class.new { include Y::ActionCable::Sync }

    assert_operator channel, :<, Y::ActionCable::Sync
  end
end
