require "test_helper"
require "y/agent"

# Inviting the demo agent into a Lexxy room: POST /demos/lexxy/:room/agent.
class AgentInviteTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ROOM = "agentroom1".freeze

  setup do
    Rack::Attack.cache.store.clear
    AgentSeats.current = AgentSeats.new(max: 2)
    Note.create!(room: ROOM)
  end

  teardown do
    AgentSeats.current = nil
    Note.delete_all
  end

  ADA = { owner: "0b6c4f0e-ada0-4c1e-9d55-6a8e0c1f2a11", name: "Ada", color: "#f87171" }.freeze
  LINUS = { owner: "7d2e1a90-11e5-4a8b-b2c3-9f0e7d6c5b44", name: "Linus", color: "#22d3ee" }.freeze

  def invite(room = ROOM, person = ADA, origin: "http://www.example.com", **)
    post "/demos/lexxy/#{room}/agent?#{person.to_query}", headers: { "Origin" => origin }, **
  end

  def owner(person) = { id: person[:owner], name: person[:name], color: person[:color] }

  test "an invitation takes the person's seat and starts their agent" do
    assert_enqueued_with(job: PageAgentJob, args: [ROOM, "http://www.example.com", owner(ADA)]) { invite }

    assert_response :accepted
    assert_equal "joining", response.parsed_body["status"]
    assert_equal 1, AgentSeats.current.count
  end

  test "a person whose agent is in the room starts no other" do
    invite

    assert_no_enqueued_jobs { invite }
    assert_equal "here", response.parsed_body["status"]
  end

  test "each person in a room brings their own agent" do
    invite

    assert_enqueued_with(job: PageAgentJob, args: [ROOM, "http://www.example.com", owner(LINUS)]) { invite(ROOM, LINUS) }
    assert_equal 2, AgentSeats.current.count
  end

  test "past the agent limit an invitation is turned away" do
    Note.create!(room: "agentroom2")
    Note.create!(room: "agentroom3")
    invite
    invite("agentroom2")

    assert_no_enqueued_jobs { invite("agentroom3") }
    assert_response :service_unavailable
    assert_equal "busy", response.parsed_body["status"]
  end

  test "an invitation without a person to belong to is refused" do
    assert_no_enqueued_jobs { invite(ROOM, ADA.merge(color: "red")) }

    assert_response :unprocessable_content
  end

  test "an invitation from another site is refused" do
    assert_no_enqueued_jobs { invite(origin: "https://evil.example") }

    assert_response :forbidden
  end

  test "a room nobody has opened has no note to join" do
    assert_no_enqueued_jobs { invite("emptyroom1") }

    assert_response :not_found
  end

  test "an invitation with a body never reaches the app" do
    invite(params: { "x" => "y" })

    assert_response :method_not_allowed
  end

  test "an IP gets a few invitations an hour" do
    Limits::AGENT_INVITES_PER_HOUR.times { invite("emptyroom1") }
    invite("emptyroom1")

    assert_response :too_many_requests
  end

  test "the job gives the seat back when the agent leaves" do
    AgentSeats.current.take(ROOM, ADA[:owner])
    run = Y::Agent.method(:run)
    Y::Agent.define_singleton_method(:run) { |*, **| raise "the model is down" }

    assert_raises(RuntimeError) { PageAgentJob.perform_now(ROOM, "http://www.example.com", owner(ADA)) }
    assert_equal 0, AgentSeats.current.count
  ensure
    Y::Agent.define_singleton_method(:run, run)
  end
end
