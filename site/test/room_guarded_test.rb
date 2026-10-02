require "test_helper"

# The demo opts out of AnyCable whispers by stripping the `whisper:` option from
# every stream_from before it reaches the channel's real one (and thus anycable-
# go). yrby enables the whisper on the awareness stream under AnyCable; this
# override removes it, so Go never whisper-enables the stream and drops every
# whisper on it. The end-to-end proof against a live anycable-go is the raw-ws
# check in frontend/raw_ws_whisper_check.mjs; this pins the method's contract.
class RoomGuardedTest < ActiveSupport::TestCase
  # A probe with a stream_from that records its calls, and RoomGuarded's own
  # stream_from spliced in above it, so a call lands on the override first and
  # falls through to `super` here, exactly as it does on a real channel. Built
  # this way to exercise the one method without the channel/Concern machinery.
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

  test "the whisper option is stripped before it reaches the real stream_from" do
    p = probe
    p.stream_from("yrby:tiptap/x:awareness", whisper: true)

    assert_equal [{ broadcasting: "yrby:tiptap/x:awareness", opts: {} }], p.calls,
                 "whisper: true must be removed, so anycable-go never whisper-enables the stream"
  end

  test "a plain stream_from is passed through untouched" do
    p = probe
    p.stream_from("yrby:tiptap/x")

    assert_equal [{ broadcasting: "yrby:tiptap/x", opts: {} }], p.calls
  end
end
