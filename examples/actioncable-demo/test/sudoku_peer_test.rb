# frozen_string_literal: true

require "sudoku_helper"
require "action_cable"
require "y/action_cable"
require "puma"
require "concurrent/timer_task" # Action Cable's heartbeat; a Rails boot loads it
require "logger"

# The checker against a real cable: Puma serving Action Cable in this
# process, a room-keyed channel that records to a hash, the checker joined
# over one socket and a player over another. Everything between them goes
# through the document.
class SudokuPeerTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- a cable of its own, then the tests
  include SudokuFixture

  STORE = Hash.new { |hash, key| hash[key] = [] }
  STORE_LOCK = Mutex.new

  class Connection < ActionCable::Connection::Base
  end

  class RoomChannel < ActionCable::Channel::Base
    include Y::ActionCable

    on_load do |key|
      updates = STORE_LOCK.synchronize { STORE[key].dup }
      next if updates.empty?

      doc = Y::Doc.new
      updates.each { |update| doc.apply_update(update) }
      doc.encode_state_as_update
    end
    on_change { |key, update| STORE_LOCK.synchronize { STORE[key] << update } }

    def subscribed = sync_subscribed(params[:id])
    def receive(data) = sync_receive(data, params[:id])

    private

    def authorized?(_key) = true
  end

  def self.port
    @port ||= begin
      server = ActionCable.server
      server.config.cable = { "adapter" => "test" }
      server.config.logger = Logger.new(File::NULL)
      server.config.connection_class = -> { Connection }
      server.config.disable_request_forgery_protection = true
      puma = Puma::Server.new(server)
      listener = puma.add_tcp_listener("127.0.0.1", 0)
      puma.run
      Minitest.after_run { puma.stop(true) }
      listener.addr[1]
    end
  end

  def setup
    @key = "sudoku-#{rand(1 << 32)}"
    @clients = []
    givens = Y::Doc.new.diff { |d| PUZZLE.to_map.each { |key, digit| d.get_map("givens")[key] = digit } }
    STORE_LOCK.synchronize { STORE[@key] << givens }
  end

  def teardown
    @checker&.stop
    @thread&.join(5)
    @clients.each(&:unsubscribe)
  end

  def client
    client = Y::ActionCable::Client.new("ws://127.0.0.1:#{self.class.port}/cable",
                                        channel: "SudokuPeerTest::RoomChannel", params: { id: @key },
                                        root: nil, logger: Logger.new(File::NULL))
    @clients << client
    client
  end

  def start_checker
    @checker = SudokuPeer.new(@key, peer: client, logger: Logger.new(File::NULL))
    @thread = Thread.new { @checker.run }
  end

  # A player joined, with everyone's presence mirrored in `seen`, the
  # checker there and done with its first look at the grid, and the player
  # then present. Presence is not replayed on a join: a browser says its own
  # again every 15 seconds, and this player says it once the checker is in.
  def join
    seen = Y::Awareness.new
    player = client.on_awareness { |frame| seen.apply_update(frame) }.subscribe
    start_checker
    wait_until { read(player, "progress").any? }
    player.send_awareness(Y::Awareness.new.set_local_state(JSON.generate(user: { name: "Ada", color: "#f00" })))
    [player, seen]
  end

  def checker_state(seen) = seen.states.values.find { |s| s.is_a?(Hash) && s["checker"] }

  def read(client, name) = JSON.parse(client.doc.read_map(name) || "{}")

  def write(client, name, key, value)
    client.send_update(client.doc.diff { |d| d.get_map(name)[key] = value })
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def test_the_checker_joins_as_a_player_and_reports_the_grid
    player, seen = join

    assert_equal({ "filled" => 30, "conflicts" => 0, "solved" => false }, read(player, "progress"))
    assert_equal({ "name" => "Checker", "color" => "#7c3aed" }, checker_state(seen)["user"])
    assert_equal "30/81", checker_state(seen)["status"]
    wait_until { @checker.send(:people_here).size == 1 } # the player; not the checker's own echoed presence
  end

  def test_a_conflict_is_flagged_in_the_document_and_cleared_with_it
    player, seen = join

    write(player, "grid", "r0c2", 5) # row 0 already has a 5 at r0c0
    wait_until { read(player, "conflicts").any? }

    assert_equal({ "r0c0" => true, "r0c2" => true }, read(player, "conflicts"))
    assert_equal({ "filled" => 31, "conflicts" => 2, "solved" => false }, read(player, "progress"))
    wait_until { checker_state(seen)["cell"] == "r0c0" }

    player.send_update(player.doc.diff { |d| d.get_map("grid").delete("r0c2") })
    wait_until { read(player, "conflicts").empty? }

    assert_equal 0, read(player, "progress")["conflicts"]
    assert_operator STORE_LOCK.synchronize { STORE[@key].size }, :>=, 5, "the server recorded the checker's writes"
  end

  def test_a_hint_fills_the_first_empty_cell_and_takes_the_request_out
    player, seen = join
    write(player, "grid", "r0c2", 5)
    wait_until { read(player, "conflicts").any? }

    write(player, "requests", "hint", 1)
    wait_until { read(player, "requests").empty? }

    assert_equal 6, read(player, "grid")["r0c3"], "the first empty cell, with the solution's digit"
    assert_equal 5, read(player, "grid")["r0c2"], "a wrong digit is left for the players"
    assert_equal 32, read(player, "progress")["filled"]
    wait_until { checker_state(seen)["cell"] == "r0c3" }
  end

  def test_a_complete_grid_is_reported_solved
    player, = join

    player.send_update(player.doc.diff do |d|
      SOLUTION.to_map.each { |key, digit| d.get_map("grid")[key] = digit unless PUZZLE.to_map.key?(key) }
    end)
    wait_until { read(player, "progress")["solved"] }

    assert_equal({ "filled" => 81, "conflicts" => 0, "solved" => true }, read(player, "progress"))
  end

  def test_the_checker_leaves_when_stopped_and_clears_its_presence
    _player, seen = join

    @checker.stop
    @thread.join(5)

    refute_predicate @thread, :alive?
    wait_until { checker_state(seen).nil? }
  end
end
