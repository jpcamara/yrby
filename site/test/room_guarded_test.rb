require "test_helper"

# The demo turns off AnyCable whispers by removing the `whisper:` option from
# every stream_from call before it reaches the channel's real stream_from and
# anycable-go. Under AnyCable, yrby turns on whispers for the awareness stream.
# This override removes that, so anycable-go drops every whisper on the
# stream. frontend/raw_ws_whisper_check.mjs tests this against a live
# anycable-go. These tests check the method itself.
class RoomGuardedTest < ActiveSupport::TestCase
  # A test object whose stream_from records its calls, with RoomGuarded's
  # stream_from prepended. A call goes to the override first and then to
  # `super`, the same as on a real channel. This tests the one method without
  # setting up a channel.
  def probe
    override = Module.new
    override.send(:define_method, :stream_from, RoomGuarded.instance_method(:stream_from))
    klass = Class.new do
      attr_reader :calls

      def stream_from(broadcasting, *_args, **opts)
        (@calls ||= []) << { broadcasting: broadcasting, opts: opts }
      end
    end
    klass.prepend(override)
    klass.new
  end

  test "the whisper option is removed before the real stream_from" do
    p = probe
    p.stream_from("yrby:tiptap/x:awareness", whisper: true)

    assert_equal [{ broadcasting: "yrby:tiptap/x:awareness", opts: {} }], p.calls,
                 "whisper: true must be removed so anycable-go does not enable whispers on the stream"
  end

  test "a plain stream_from is passed through unchanged" do
    p = probe
    p.stream_from("yrby:tiptap/x")

    assert_equal [{ broadcasting: "yrby:tiptap/x", opts: {} }], p.calls
  end
end
