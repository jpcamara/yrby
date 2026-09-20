# frozen_string_literal: true

require "city_helper"
require "action_cable"
require "y/action_cable"
require "puma"
require "concurrent/timer_task" # Action Cable's heartbeat; a Rails boot loads it
require "logger"

# The planner against a real cable: Puma serving Action Cable in this
# process, a room-keyed channel that records to a hash, the planner joined
# over one socket and a person over another. Everything between them goes
# through the document.
class CityPlannerTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- a cable of its own, then the tests
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
    @key = "city-#{rand(1 << 32)}"
    @clients = []
  end

  def teardown
    @planner&.stop
    @thread&.join(5)
    @clients.each(&:unsubscribe)
  end

  def client
    client = Y::ActionCable::Client.new("ws://127.0.0.1:#{self.class.port}/cable",
                                        channel: "CityPlannerTest::RoomChannel", params: { id: @key },
                                        root: nil, logger: Logger.new(File::NULL))
    @clients << client
    client
  end

  # A person joined, with everyone's presence mirrored in `seen`, and the
  # planner there and idle. Presence is not replayed on a join, so the
  # person says theirs once the planner is in.
  def join
    seen = Y::Awareness.new
    person = client.on_awareness { |frame| seen.apply_update(frame) }.subscribe
    @planner = CityPlanner.new(@key, peer: client, logger: Logger.new(File::NULL))
    @thread = Thread.new { @planner.run }
    wait_until { planner_state(seen) }
    person.send_awareness(Y::Awareness.new.set_local_state(JSON.generate(user: { name: "Ada", color: "#f00" },
                                                                         pos: { x: 0, y: 0 })))
    [person, seen]
  end

  def planner_state(seen) = seen.states.values.find { |s| s.is_a?(Hash) && s["planner"] }

  def read(client, name) = JSON.parse(client.doc.read_map(name) || "{}")

  # What the page writes for a paint: the tile and its author together.
  def paint(client, cells, tile, name: "Ada")
    client.send_update(client.doc.diff do |d|
      cells.each do |x, y|
        d.get_map("tiles")[City.key(x, y)] = tile
        d.get_map("authors")[City.key(x, y)] = "h:#{name}"
      end
    end)
  end

  # What the page writes for a sign: the tile, its author, and the text.
  def place_sign(client, cell, text)
    client.send_update(client.doc.diff do |d|
      d.get_map("tiles")[City.key(*cell)] = "sign"
      d.get_map("authors")[City.key(*cell)] = "h:Ada"
      d.get_map("signs")[City.key(*cell)] = text
    end)
  end

  # The planner's presence once it says it is idle.
  def idle(seen)
    wait_until { planner_state(seen)["status"] == "idle" }
    planner_state(seen)
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def test_the_planner_joins_as_a_peer_and_connects_two_houses_with_a_road
    person, seen = join

    assert_equal({ "name" => "Planner", "color" => "#e38628" }, planner_state(seen)["user"])
    assert_equal "idle", planner_state(seen)["status"]

    paint(person, [[10, 10]], "house_red")
    paint(person, [[16, 10]], "house_blue")
    road = (11..15).map { |x| City.key(x, 10) }
    wait_until(timeout: 15) { road.all? { |k| read(person, "tiles")[k] == "road" } }

    assert_equal road.to_h { |k| [k, "a:planner"] }, read(person, "authors").slice(*road), "the planner signed its road"
    wait_until { read(person, "claims").empty? }

    assert_equal({ "x" => 15, "y" => 10 }, idle(seen)["pos"], "its character stands on the last tile it laid")
    assert_operator STORE_LOCK.synchronize { STORE[@key].size }, :>=, 7, "the server recorded the planner's writes"
  end

  def test_the_planner_claims_the_cells_first_and_yields_when_someone_writes_beside_them
    person, seen = join

    paint(person, [[2, 20]], "house_red")
    paint(person, [[40, 20]], "house_blue")
    wait_until { read(person, "claims").size >= 30 }

    assert(read(person, "claims").values.all? { |v| v == "planner" })
    paint(person, [[20, 22]], "park")
    wait_until { planner_state(seen)["status"] == "yielding to Ada" }
    wait_until { read(person, "claims").empty? }

    laid = read(person, "tiles").count { |_, tile| tile == "road" }

    assert_operator laid, :<, 37, "it stopped short"
    idle(seen)
  end

  def test_a_park_sign_gets_a_park_and_a_bridge_sign_a_bridge
    person, seen = join

    place_sign(person, [30, 30], "PARK")
    paint(person, [[6, 5], [6, 6], [6, 7]], "water")
    place_sign(person, [5, 6], "BRIDGE")
    wait_until(timeout: 15) do
      tiles = read(person, "tiles")
      tiles["6,6"] == "bridge" &&
        tiles.any? { |k, tile| tile == "park" && City.distance(City.parse_key(k), [30, 30]) <= 2 }
    end

    assert_equal "a:planner", read(person, "authors")["6,6"]
    idle(seen)
  end

  def test_the_planner_leaves_when_stopped_and_clears_its_presence
    _person, seen = join

    @planner.stop
    @thread.join(5)

    refute_predicate @thread, :alive?
    wait_until { planner_state(seen).nil? }
  end
end
