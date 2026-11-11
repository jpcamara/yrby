require "test_helper"
require "y/agent"

# The agent sheet's page, its document, and inviting an agent to it.
# test/sheet_agent_test.rb covers the agent itself.
class SheetPageTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ORIGIN = "http://www.example.com".freeze
  ADA = { owner: "0b6c4f0e-ada0-4c1e-9d55-6a8e0c1f2a11", name: "Ada", color: "#f87171" }.freeze

  setup do
    Rack::Attack.cache.store.clear
    AgentSeats.current = AgentSeats.new(max: 2)
  end

  teardown do
    AgentSeats.current = nil
    Room.delete_all
  end

  def invite(room = "sheetroom1", person = ADA, **)
    post "/demos/spreadsheet/#{room}/agent?#{person.to_query}", headers: { "Origin" => ORIGIN }, **
  end

  test "/sheet starts a new room's sheet" do
    get "/sheet"

    assert_response :redirect
    assert_match %r{/demos/spreadsheet/[A-Za-z0-9_-]+/sheet\z}, response.location
  end

  test "the sheet of a room nobody has started offers to start it, and starting goes back to the sheet" do
    get "/demos/spreadsheet/sheetroom1/sheet"

    assert_response :not_found
    assert_equal 0, Room.count
    assert_includes response.body, %(action="/demos/spreadsheet/sheetroom1/start?sheet=1")

    post "/demos/spreadsheet/sheetroom1/start?sheet=1", headers: { "Origin" => ORIGIN }

    assert_redirected_to "/demos/spreadsheet/sheetroom1/sheet"
  end

  test "the sheet joins the room's sheet document over RoomChannel" do
    room = Room.create!(slug: "sheetroom1")

    get "/demos/spreadsheet/sheetroom1/sheet"

    assert_response :success
    element = response.body[/<yrby-document [^>]+>/]

    assert_includes element, %(channel="RoomChannel")
    assert_includes element, %(name="sheet")
    assert_includes response.body, "/sheet.js"
    assert_includes response.body, %(data-url="/demos/spreadsheet/sheetroom1/agent")
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "RoomChannel", room.collaborative_document(:sheet).channel
  end

  test "an invitation from the sheet starts a sheet agent" do
    Room.create!(slug: "sheetroom1")

    owner = { id: ADA[:owner], name: "Ada", color: "#f87171" }
    assert_enqueued_with(job: SheetAgentJob, args: ["sheetroom1", ORIGIN, owner]) { invite }
    assert_response :accepted
  end

  test "a query string can't turn a Lexxy invitation into a sheet agent" do
    Room.create!(slug: "sheetroom1")

    assert_enqueued_with(job: PageAgentJob) do
      post "/demos/lexxy/sheetroom1/agent?#{ADA.merge(sheet: 1).to_query}", headers: { "Origin" => ORIGIN }
    end
  end

  test "an invitation with a body never reaches the app" do
    Room.create!(slug: "sheetroom1")
    invite(params: { "x" => "y" })

    assert_response :method_not_allowed
  end

  test "the job gives the seat back when the agent leaves" do
    Room.create!(slug: "sheetroom1")
    AgentSeats.current.take("sheetroom1", ADA[:owner])
    run = SheetAgent.method(:run)
    SheetAgent.define_singleton_method(:run) { |*, **| raise "the model is down" }

    assert_raises(RuntimeError) do
      SheetAgentJob.perform_now("sheetroom1", ORIGIN, { id: ADA[:owner], name: "Ada", color: "#f87171" })
    end
    assert_equal 0, AgentSeats.current.count
  ensure
    SheetAgent.define_singleton_method(:run, run)
  end
end

# RoomChannel opens a room's sheet document with the sheet's grant.
class SheetChannelTest < ActionCable::Channel::TestCase
  tests RoomChannel

  setup do
    stub_connection(connection_id: "c1")
    @room = Room.create!(slug: "sheetroom1")
  end

  teardown { Room.delete_all }

  test "the sheet's grant subscribes" do
    subscribe(grant: @room.collaborative_document(:sheet).grant, name: "sheet")

    assert_predicate subscription, :confirmed?
  end

  test "another document's grant doesn't open the sheet" do
    subscribe(grant: @room.collaborative_document(:spreadsheet).grant, name: "sheet")

    assert_predicate subscription, :rejected?
  end
end
