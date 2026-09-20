# frozen_string_literal: true

require "guest_helper"

# One guest: when it asks, what it stands at, and when it leaves.
# rubocop:disable-next Metrics/AbcSize -- assertion-dense, like the gem's tests
class GuestTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- assertion-dense, like the gem's tests
  include GuestFixture

  def setup
    @peer = Peer.new
    @mind = Mind.new
    @log = StringIO.new
    @peer.sign("s1", "FREE PIZZA")
    @peer.sign("s2", "QUIET ROOM", left: 500, top: 20)
  end

  def teardown
    @guest&.stop
    @thread&.join(3)
    raise "the guest leaked its thread" if @thread&.alive?
  end

  def start(**)
    @guest = Guest.new("room:cursors", PERSONA, peer: @peer, mind: @mind, quiet: 0.04, min_interval: 0.05,
                                                logger: Logger.new(@log), **)
    @thread = Thread.new { @guest.run }
    take_call
  end

  def take_call = @mind.calls.pop(timeout: 3) || raise("the mind wasn't asked")

  def decision(choice, options = %w[s1 s2 stay])
    rest = (1.0 - 0.9) / (options.size - 1)
    GuestMind::Decision.new(choice: choice, probabilities: options.to_h { |o| [o, o == choice ? 0.9 : rest] },
                            confidence: 0.93, ms: 512.0, model: "jev-1.13.0")
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def events = @log.string.lines.map { |line| JSON.parse(line[line.index("{")..]) }

  def test_decides_on_joining_and_stands_at_the_chosen_sign
    asked = start

    assert_equal [["s1", "FREE PIZZA"], ["s2", "QUIET ROOM"]], asked[:signs]
    assert_nil asked[:current]
    assert_equal "Snack Goblin", asked[:persona].name
    assert_equal "deciding", @peer.state["status"]
    @mind.responses << decision("s2")
    wait_until { @peer.state["at"] == "s2" }
    state = @peer.state

    assert_equal "settled", state["status"]
    assert_equal({ "name" => "Snack Goblin", "color" => "#d97706" }, state["user"])
    assert state["guest"]
    assert_equal "lives for free food", state["trait"]
    assert_equal [60, 60], state["home"]
    assert_equal "s2", state.dig("decision", "choice")
    assert_equal "s2", state.dig("decision", "sign")
    assert_in_delta 0.9, state.dig("decision", "p")
    assert_in_delta 512.0, state.dig("decision", "ms")
    assert_equal "jev-1.13.0", state.dig("decision", "model")
    assert_kind_of Integer, state.dig("decision", "at")
    decided = events.find { |e| e["event"] == "guest_decision" }

    assert_equal "ok", decided["status"]
    assert_equal 2, decided["signs"]
    refute_includes @log.string, "PIZZA"
    refute_includes @log.string, "QUIET"
  end

  def test_a_text_change_asks_once_after_the_quiet_and_two_quick_edits_ask_once
    start
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.retext("s2", "MANDATORY")
    @peer.retext("s2", "KARAOKE")
    asked = take_call

    assert_equal [["s1", "FREE PIZZA"], ["s2", "KARAOKE"]], asked[:signs]
    assert_equal "s1", asked[:current]
    @mind.responses << decision("s2")
    wait_until { @peer.state["at"] == "s2" }
    sleep 0.2

    assert_empty @mind.calls, "two edits inside the quiet are one question"
  end

  def test_moving_a_sign_asks_nothing
    start
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.move("s1", 300, 200)
    @peer.move("s1", 320, 210)
    sleep 0.2

    assert_empty @mind.calls
    assert_equal "s1", @peer.state["at"]
  end

  def test_a_stale_answer_is_dropped_and_the_question_asked_again
    start
    @peer.retext("s1", "STALE PIZZA")
    @mind.responses << decision("s1")
    asked = take_call

    assert_equal [["s1", "STALE PIZZA"], ["s2", "QUIET ROOM"]], asked[:signs]
    assert_nil @peer.state["at"], "an answer about the old signs must not stand"
    @mind.responses << decision("s2")
    wait_until { @peer.state["at"] == "s2" }

    assert_equal(1, events.count { |e| e["event"] == "guest_decision" })
  end

  def test_staying_keeps_the_sign
    start
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.retext("s2", "LOUD ROOM")
    asked = take_call

    assert_equal "s1", asked[:current]
    @mind.responses << decision("stay")
    wait_until { @peer.state.dig("decision", "choice") == "stay" }

    assert_equal "s1", @peer.state["at"]
    assert_equal "stay", @peer.state.dig("decision", "sign")
  end

  def test_a_sign_taken_down_is_decided_again_without_it
    start
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.unsign("s1")
    asked = take_call

    assert_equal [["s2", "QUIET ROOM"]], asked[:signs]
    assert_nil asked[:current]
    assert_nil @peer.state["at"]
    @mind.responses << decision("s2", %w[s2 stay])
    wait_until { @peer.state["at"] == "s2" }
  end

  def test_the_briefing_goes_with_every_question
    asked = start(briefing: { "Quiet Room" => "soft chairs" })

    assert_equal({ "Quiet Room" => "soft chairs" }, asked[:briefing])
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.retext("s2", "LOUD ROOM")

    assert_equal({ "Quiet Room" => "soft chairs" }, take_call[:briefing])
    @mind.responses << decision("stay")
  end

  def test_a_blank_sign_is_not_a_sign
    @peer.sign("s3", "   ")
    asked = start

    assert_equal %w[s1 s2], asked[:signs].map(&:first)
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.retext("s3", "CAT CAFE")
    asked = take_call

    assert_equal %w[s1 s2 s3], asked[:signs].map(&:first)
    @mind.responses << decision("s3", %w[s1 s2 s3 stay])
    wait_until { @peer.state["at"] == "s3" }
  end

  def test_no_signs_means_nowhere_to_go_and_no_question
    @peer.unsign("s1")
    @peer.unsign("s2")
    @guest = Guest.new("room:cursors", PERSONA, peer: @peer, mind: @mind, quiet: 0.04, min_interval: 0.05,
                                                logger: Logger.new(@log))
    @thread = Thread.new { @guest.run }
    wait_until { @peer.state&.fetch("status", nil) == "settled" }

    assert_nil @peer.state["at"]
    sleep 0.15

    assert_empty @mind.calls
  end

  def test_the_party_ending_sends_the_guest_home
    start
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.human { |doc| doc.get_map("party")["enabled"] = false }
    @thread.join(2)

    refute_predicate @thread, :alive?
    assert @peer.unsubscribed
    assert_empty @peer.presence.states.values.compact
    assert_equal "party over", events.find { |e| e["event"] == "guest_left" }["why"]
  end

  def test_stop_leaves_even_while_the_mind_is_out
    start
    @guest.stop
    @thread.join(2)

    refute_predicate @thread, :alive?
    assert @peer.unsubscribed
    assert_empty @peer.presence.states.values.compact
  end

  def test_a_confused_guest_stays_and_asks_again_on_the_next_change
    start
    @mind.responses << GuestMind::Error.new("RubyLLM::ServerError")
    wait_until { @peer.state["status"] == "confused" }

    assert_nil @peer.state["decision"]
    assert_predicate @thread, :alive?
    failed = events.find { |e| e["event"] == "guest_decision" }

    assert_equal "error", failed["status"]
    assert_equal "RubyLLM::ServerError", failed["error_class"]
    sleep 0.15

    assert_empty @mind.calls, "an error does not ask again by itself"
    @peer.retext("s1", "FREE PIZZA, REALLY")
    take_call
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }

    assert_equal "settled", @peer.state["status"]
  end

  def test_two_questions_are_at_least_min_interval_apart
    start(min_interval: 0.3)
    first = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    @peer.retext("s2", "QUIETER ROOM")
    take_call
    second = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_operator second - first, :>=, 0.28
    @mind.responses << decision("stay")
  end

  # On a reactor the mind is a task, not a thread: nothing new appears in
  # Thread.list while the question is out, the loop keeps yielding, and the
  # answer still lands.
  def test_on_a_reactor_the_mind_is_a_task_not_a_thread
    require "async"
    @guest = Guest.new("room:cursors", PERSONA, peer: @peer, mind: @mind, quiet: 0.04, min_interval: 0.05,
                                                logger: Logger.new(@log))
    @thread = Thread.new { Sync { @guest.run } }
    take_call
    threads = Thread.list.size
    sleep 0.2

    assert_equal threads, Thread.list.size, "a question in flight must not add a thread"
    @peer.person(Y::Awareness.new(7).set_local_state(JSON.generate(user: { name: "Ada" }, cursor: { x: 1, y: 2 })))
    wait_until { @guest.send(:people_here) == [7] }
    @mind.responses << decision("s2")
    wait_until { @peer.state["at"] == "s2" }

    assert_equal "settled", @peer.state["status"]
    assert_equal threads, Thread.list.size
  end

  def test_on_a_reactor_stop_cuts_a_question_short
    require "async"
    @guest = Guest.new("room:cursors", PERSONA, peer: @peer, mind: @mind, quiet: 0.04, min_interval: 0.05,
                                                logger: Logger.new(@log))
    @thread = Thread.new { Sync { @guest.run } }
    take_call
    @guest.stop
    @thread.join(2)

    refute_predicate @thread, :alive?
    assert @peer.unsubscribed
    assert_empty @peer.presence.states.values.compact
  end

  def test_only_people_keep_the_room_open
    start
    @mind.responses << decision("s1")
    wait_until { @peer.state["at"] == "s1" }
    other = Y::Awareness.new(7)
    @peer.person(other.set_local_state(JSON.generate(user: { name: "Ada", color: "#f87171" }, cursor: { x: 1, y: 2 })))
    guest = Y::Awareness.new(8)
    @peer.person(guest.set_local_state(JSON.generate(user: { name: "Lurker" }, guest: true)))
    wait_until { @guest.send(:people_here) == [7] }

    assert_equal [7], @guest.send(:people_here)
  end
end
