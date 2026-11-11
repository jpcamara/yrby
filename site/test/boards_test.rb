require "test_helper"
require "y/agent"

# The agent board's page, starting a board, and inviting an agent onto one.
# test/board_agent_test.rb covers what the agent does there.
class BoardsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ROOM = "boardroom1".freeze
  ORIGIN = "http://www.example.com".freeze
  ADA = { owner: "0b6c4f0e-ada0-4c1e-9d55-6a8e0c1f2a11", name: "Ada", color: "#f87171" }.freeze

  setup do
    Rack::Attack.cache.store.clear
    AgentSeats.current = AgentSeats.new(max: 2)
  end

  teardown { AgentSeats.current = nil }

  def room = Room.find_by!(slug: ROOM)

  def invite(person = ADA, origin: ORIGIN, **)
    post "/demos/board/#{ROOM}/agent?#{person.to_query}", headers: { "Origin" => origin }, **
  end

  test "/board starts a new board" do
    get "/board"

    assert_response :redirect
    assert_match %r{/demos/board/[A-Za-z0-9_-]+\z}, response.location
  end

  test "a board nobody has started offers to start it, and a GET doesn't" do
    get "/demos/board/#{ROOM}"

    assert_response :not_found
    assert_equal 0, Room.count
    assert_includes response.body, %(action="/demos/board/#{ROOM}/start")
  end

  test "starting a board creates the room and goes to it" do
    post "/demos/board/#{ROOM}/start", headers: { "Origin" => ORIGIN }

    assert_redirected_to "/demos/board/#{ROOM}"
    assert Room.exists?(slug: ROOM)
  end

  test "starting a board from another site is refused" do
    post "/demos/board/#{ROOM}/start", headers: { "Origin" => "https://evil.example" }

    assert_response :forbidden
    assert_equal 0, Room.count
  end

  test "the board joins the room's board document on its own channel" do
    Room.create!(slug: ROOM)

    get "/demos/board/#{ROOM}"

    assert_response :success
    element = response.body[/<yrby-document [^>]+>/]

    assert_includes element, %(channel="BoardChannel")
    assert_includes element, %(name="board")
    assert_includes response.body, "/board.js"
    assert_includes response.body, %(data-agent-url="/demos/board/#{ROOM}/agent")
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "a malformed board is not found" do
    get "/demos/board/#{"a" * 33}"

    assert_response :not_found
  end

  test "an invitation takes the person's board seat and starts their agent" do
    Room.create!(slug: ROOM)
    owner = { id: ADA[:owner], name: "Ada", color: "#f87171" }

    assert_enqueued_with(job: BoardAgentJob, args: [ROOM, ORIGIN, owner]) { invite }
    assert_response :accepted
    assert_no_enqueued_jobs { invite }
    assert_equal "here", response.parsed_body["status"]
  end

  test "a person's board agent and their Lexxy agent take separate seats" do
    Room.create!(slug: ROOM)
    AgentSeats.current.take(ROOM, ADA[:owner])

    assert_enqueued_with(job: BoardAgentJob) { invite }
    assert_equal 2, AgentSeats.current.count
  end

  test "invitations are refused from another site, without a person, or for no board" do
    invite

    assert_response :not_found

    Room.create!(slug: ROOM)
    assert_no_enqueued_jobs do
      invite(origin: "https://evil.example")

      assert_response :forbidden
      invite(ADA.merge(color: "red"))

      assert_response :unprocessable_content
    end
  end

  test "an invitation with a body never reaches the app" do
    Room.create!(slug: ROOM)
    invite(params: { "x" => "y" })

    assert_response :method_not_allowed
  end

  test "the job gives the seat back when the agent leaves" do
    Room.create!(slug: ROOM)
    AgentSeats.current.take(BoardsController.seat(ROOM), ADA[:owner])
    run = Y::Agent.method(:run)
    Y::Agent.define_singleton_method(:run) { |*, **| raise "the model is down" }

    assert_raises(RuntimeError) do
      BoardAgentJob.perform_now(ROOM, ORIGIN, { id: ADA[:owner], name: "Ada", color: "#f87171" })
    end
    assert_equal 0, AgentSeats.current.count
  ensure
    Y::Agent.define_singleton_method(:run, run)
  end
end

# BoardChannel opens a room's board, and nothing else.
class BoardChannelTest < ActionCable::Channel::TestCase
  tests BoardChannel

  setup do
    stub_connection(connection_id: "c1")
    @room = Room.create!(slug: "room1")
    connection.define_singleton_method(:close) { |**| nil }
  end

  test "a board's grant subscribes" do
    subscribe grant: @room.collaborative_document(:board).grant, name: "board"

    assert_predicate subscription, :confirmed?
  end

  test "another document's grant doesn't open here" do
    subscribe grant: @room.collaborative_document(:whiteboard).grant, name: "whiteboard"

    assert_predicate subscription, :rejected?
  end

  test "receive is the only action a client can call" do
    assert_equal Set["receive"], BoardChannel.action_methods
  end
end

# The shape demos' channel doesn't open the board.
class BoardOnRoomChannelTest < ActionCable::Channel::TestCase
  tests RoomChannel

  setup do
    stub_connection(connection_id: "c1")
    connection.define_singleton_method(:close) { |**| nil }
  end

  test "a board's grant doesn't open on RoomChannel" do
    subscribe grant: Room.create!(slug: "room1").collaborative_document(:board).grant, name: "board"

    assert_predicate subscription, :rejected?
  end
end
