# frozen_string_literal: true

require "minitest/autorun"
require "y"
require_relative "../app/lib/pixel_artist"

# Real Y documents with a narrow cable seam. Network delivery is covered by
# the cable suite; here we control exactly when a model reply races an edit.
class PixelArtistTest < Minitest::Test
  class Peer
    attr_reader :doc, :presence, :unsubscribed, :updates

    def initialize
      @doc = Y::Doc.new
      @presence = Y::Awareness.new
      @updates = []
      @doc.get_map("scene")["0,0"] = 13
      @doc.get_map("mural")["brief"] = "Follow our postcard"
    end

    def on_update(&block) = @on_update = block
    def on_awareness(&block) = @on_awareness = block
    def subscribe = self
    def unsubscribe = @unsubscribed = true
    def send_awareness(frame) = @presence.apply_update(frame)

    def send_update(update)
      return unless update

      @updates << update
      @on_update&.call(update, doc, []) # echo tests own-write loop suppression
    end

    def human(map, key, value)
      update = doc.diff { |document| document.get_map(map)[key] = value }
      @on_update&.call(update, doc, [])
    end

    def read(map) = JSON.parse(doc.read_map(map) || "{}")
  end

  class Planner
    attr_reader :calls, :responses
    def initialize
      @calls = Queue.new
      @responses = Queue.new
    end

    def model = "test/planner"

    def call(snapshot, **options)
      @calls << [snapshot, options]
      response = @responses.pop
      raise response if response.is_a?(Exception)

      response
    end
  end

  def setup
    @peer = Peer.new
    @planner = Planner.new
    @room = "pixel-#{object_id}"
  end

  def teardown
    @artist&.stop
    @thread&.join(3)
    refute @thread&.alive?, "artist should not leak its main thread"
  end

  def start(**options)
    @artist = PixelArtist.new(@room, peer: @peer, planner: @planner, quiet: 0.04, interval: 0.07,
                                   logger: Logger.new(File::NULL), **options)
    @thread = Thread.new { @artist.run }
    take_call
  end

  def take_call
    @planner.calls.pop(timeout: 3) || raise("model wasn't called")
  end

  def plan(points = [[4, 4, 9]], note: "A little sunlight")
    PixelCanvas.plan(note: note, pixels: points)
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def test_initial_model_patch_is_painted_without_touching_human_or_scene_layers
    @peer.human("pixels", "4,4", 0)
    snapshot, = start
    assert_equal 0, snapshot[4, 4]
    @planner.responses << plan([[4, 4, 9], [5, 4, 9]])
    wait_until { @peer.read("mural")["turns"] == 1 }
    assert_equal({ "5,4" => 9 }, @peer.read("artist_pixels"))
    assert_equal({ "4,4" => 0 }, @peer.read("pixels"))
    assert_equal({ "0,0" => 13 }, @peer.read("scene"))
    assert_equal "llm", @peer.read("mural")["mode"]
    assert_equal 1, @peer.read("mural")["changed"]
    state = @peer.presence.states.values.find { |value| value["artist"] }
    assert_equal "Ruby", state.dig("user", "name")
    assert_equal "5,4", state["cell"]
    sleep 0.2
    assert @planner.calls.empty?, "artist pixels and status echoes must not prompt another call"
  end

  def test_a_human_edit_spontaneously_triggers_a_plan_with_the_visual_delta
    start
    @planner.responses << plan
    wait_until { @peer.read("mural")["turns"] == 1 }
    @peer.human("pixels", "8,7", 6)
    snapshot, options = take_call
    assert_equal 6, snapshot[8, 7]
    assert_equal [{ "at" => "8,7", "from" => nil, "to" => 6 }], options[:changes]
    assert_equal "A little sunlight", options[:previous_note]
    @planner.responses << plan([[9, 7, 7]], note: "Echoed your warm color")
    wait_until { @peer.read("mural")["turns"] == 2 }
    assert_equal 7, @peer.read("artist_pixels")["9,7"]
  end

  def test_stale_inference_is_discarded_and_replanned_after_human_change
    start
    @peer.human("pixels", "4,4", 6)
    @planner.responses << plan([[10, 10, 9]])
    snapshot, = take_call
    assert_equal 6, snapshot[4, 4]
    assert_empty @peer.read("artist_pixels"), "none of the stale plan may paint"
    @planner.responses << plan([[5, 4, 7]])
    wait_until { @peer.read("mural")["turns"] == 1 }
    assert_equal({ "5,4" => 7 }, @peer.read("artist_pixels"))
  end

  def test_changing_the_brief_during_inference_also_discards_the_plan
    start
    @peer.human("mural", "brief", "A purple foggy morning")
    @planner.responses << plan
    snapshot, = take_call
    assert_equal "A purple foggy morning", snapshot.brief
    assert_empty @peer.read("artist_pixels")
    @planner.responses << plan([], note: "Leaving the composition open")
    wait_until { @peer.read("mural")["turns"] == 1 }
  end

  def test_stopping_during_inference_cancels_the_worker_and_clears_presence
    start
    assert PixelArtist.running?(@room)
    @peer.human("mural", "enabled", false)
    @thread.join(2)
    refute @thread.alive?
    assert @peer.unsubscribed
    assert_empty @peer.presence.states.values.compact
    assert_empty @peer.read("artist_pixels")
    refute PixelArtist.running?(@room)
  end

  def test_cancelling_while_subscribe_is_pending_does_not_resurrect_the_artist
    entered = Queue.new
    resume = Queue.new
    @peer.define_singleton_method(:subscribe) { entered << true; resume.pop; self }
    @artist = PixelArtist.new(@room, peer: @peer, planner: @planner, logger: Logger.new(File::NULL))
    @thread = Thread.new { @artist.run }
    assert entered.pop(timeout: 3), "artist should begin connecting"

    @peer.human("mural", "stop_version", "cancelled-during-subscribe")
    @peer.human("mural", "enabled", false)
    updates_before_join = @peer.updates.size
    resume << true
    @thread.join(2)
    refute @thread.alive?, "a cancelled invitation must leave without calling the model"
    assert_equal false, @thread.value
    assert_empty @planner.calls
    assert_empty @peer.presence.states.values.compact
    assert_equal updates_before_join, @peer.updates.size, "a cancelled invitation must not publish state"
    assert_equal false, @peer.read("mural")["enabled"]
    assert @peer.unsubscribed
    refute PixelArtist.running?(@room)
  ensure
    resume << true if resume
  end

  def test_a_new_invitation_with_the_current_stop_version_can_join
    @peer.human("mural", "stop_version", "previous-cancellation")
    @peer.human("mural", "enabled", false)
    start(stop_version: "previous-cancellation")
    assert_equal true, @peer.read("mural")["enabled"]
    @planner.responses << plan
    wait_until { @peer.read("mural")["turns"] == 1 }
    assert_equal({ "4,4" => 9 }, @peer.read("artist_pixels"))
  end

  def test_a_changed_stop_version_cancels_even_if_enabled_is_still_true
    start
    @peer.human("mural", "stop_version", "a-new-cancellation")
    @thread.join(2)
    refute @thread.alive?
    assert @peer.unsubscribed
    assert_empty @peer.presence.states.values.compact
    assert_empty @peer.read("artist_pixels")
    assert_equal false, @peer.read("mural")["enabled"]
  end

  def test_invalid_model_batch_reports_an_error_and_never_partially_paints
    start
    @planner.responses << PixelCanvas::Plan.new(note: "Bad patch", pixels: [[1, 1, 4], [65, 1, 4]])
    wait_until { @peer.read("mural")["phase"] == "error" }
    assert_empty @peer.read("artist_pixels")
    assert_includes @peer.read("mural")["note"], "outside"
    sleep 0.2
    assert @planner.calls.empty?, "an error must not automatically make more model calls"
  end

  def test_only_one_artist_can_join_a_room_in_this_process
    start
    other_peer = Peer.new
    other = PixelArtist.new(@room, peer: other_peer, planner: @planner)
    refute other.run
    assert PixelArtist.running?(@room)
    refute other_peer.unsubscribed, "a rejected duplicate never opened a socket"
  end

  def test_cleanup_releases_the_room_and_clears_presence_even_if_the_final_write_fails
    start
    @thread.report_on_exception = false
    @peer.define_singleton_method(:send_update) { |_update| raise "simulated cleanup failure" }
    @artist.stop
    assert_raises(RuntimeError) { @thread.join(2) }
    @thread = nil
    refute PixelArtist.running?(@room)
    assert @peer.unsubscribed
    assert_empty @peer.presence.states.values.compact
  end

  def test_new_edits_interrupt_remaining_strokes_of_a_large_plan
    start
    @planner.responses << plan(Array.new(96) { |i| [i % 64, i / 64 + 12, 9] })
    wait_until { @peer.read("artist_pixels").size >= 8 }
    @peer.human("pixels", "40,12", 6)
    snapshot, = take_call
    assert_equal 6, snapshot[40, 12]
    assert_operator @peer.read("artist_pixels").size, :<, 96
    @planner.responses << plan([], note: "Following the new shape")
    wait_until { @peer.read("mural")["turns"] == 1 }
    assert_equal 6, PixelCanvas.capture(@peer.doc)[40, 12]
  end
end
