# frozen_string_literal: true

require "guest_helper"
require_relative "../app/lib/guest_party"

# The party as a whole: eight peers, one per persona, started together and
# sent home together; one party per room.
# rubocop:disable-next Metrics/AbcSize -- assertion-dense, like the gem's tests
class GuestPartyTest < Minitest::Test
  def setup
    @peers = {}
    @room = "party-#{object_id}:cursors"
    @party = GuestParty.new(@room, peers: ->(persona) { @peers[persona.name] = GuestFixture::Peer.new },
                                   mind: GuestFixture::Mind.new, logger: Logger.new(File::NULL))
  end

  def teardown
    @party.stop
    @thread&.join(3)
    raise "the party leaked its thread" if @thread&.alive?
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def test_eight_distinct_personas
    assert_equal 8, GuestParty::PERSONAS.size
    assert_equal 8, GuestParty::PERSONAS.map(&:name).uniq.size
    assert_equal 8, GuestParty::PERSONAS.map(&:color).uniq.size
    assert_equal 8, GuestParty::PERSONAS.map(&:home).uniq.size
    GuestParty::PERSONAS.each do |persona|
      refute_empty persona.trait
      refute_empty persona.personality
    end
  end

  def test_eight_guests_arrive_together_and_leave_together
    @thread = Thread.new { @party.run }
    wait_until { @peers.size == 8 && @peers.values.all? { |peer| peer.state&.fetch("status", nil) == "settled" } }

    assert GuestParty.running?(@room)
    assert_equal GuestParty::PERSONAS.map(&:name).sort, @peers.values.map { |peer| peer.state.dig("user", "name") }.sort
    assert(@peers.values.all? { |peer| peer.state["at"].nil? }, "no signs, so nowhere to stand")
    @party.stop
    @thread.join(3)

    refute_predicate @thread, :alive?
    assert @thread.value
    assert(@peers.values.all?(&:unsubscribed))
    assert(@peers.values.all? { |peer| peer.presence.states.values.compact.empty? })
    refute GuestParty.running?(@room)
  end

  # Under a reactor every guest is a child task; the party adds no threads.
  def test_on_a_reactor_the_guests_are_tasks
    require "async"
    threads = Thread.list.size
    @thread = Thread.new { Sync { @party.run } }
    wait_until { @peers.size == 8 && @peers.values.all? { |peer| peer.state&.fetch("status", nil) == "settled" } }

    assert_equal threads + 1, Thread.list.size, "only the reactor's own thread"
    @party.stop
    @thread.join(3)

    refute_predicate @thread, :alive?
    assert(@peers.values.all?(&:unsubscribed))
    refute GuestParty.running?(@room)
  end

  def test_one_party_per_room
    @thread = Thread.new { @party.run }
    wait_until { @peers.size == 8 }
    other_peers = []
    other = GuestParty.new(@room, peers: lambda { |_persona|
      other_peers << GuestFixture::Peer.new
      other_peers.last
    },
                                  mind: GuestFixture::Mind.new, logger: Logger.new(File::NULL))

    refute other.run
    assert_empty other_peers, "a rejected party never makes a peer"
    assert GuestParty.running?(@room)
  end
end
