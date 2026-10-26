require "y/agent"

# Runs one person's agent in a Lexxy room until it leaves. DemosController#agent
# takes the agent's seat before it enqueues this, and the job gives it back.
class PageAgentJob < ActiveJob::Base
  # The agent's view of the room's document: what Y::Agent needs to join it.
  # The grant is the room token the page uses, and NoteChannel turns it into
  # the room's Note.
  RoomDocument = Data.define(:room) do
    def key = "note/#{room}/body"
    def name = "body"
    def grant(**) = Note.room_token(room, :body)
  end

  # `origin` is the site's origin as the inviting browser saw it. The agent
  # joins the cable at that origin, unless AGENT_CABLE_URL names another way
  # in, and sends it as its Origin, which the cable checks like a browser's.
  #
  # Each person in a room can bring an agent, so Y::Agent's one-agent-per-
  # document lock is off (lock: nil). AgentSeats counts agents per room and
  # per person instead.
  def perform(room, origin, owner)
    owner = owner.symbolize_keys
    url = ENV.fetch("AGENT_CABLE_URL") { "#{origin.sub(/\Ahttp/, "ws")}/cable" }
    page_agent = nil
    Y::Agent.run(RoomDocument.new(room), url: url, channel: "NoteChannel", lock: nil,
                                         headers: { "Origin" => origin },
                                         idle: Limits::AGENT_IDLE, max_stay: Limits::AGENT_MAX_STAY) do |agent|
      page_agent = PageAgent.new(agent, owner: PageAgent::Owner.new(**owner))
      page_agent.start
    end
  ensure
    page_agent&.stop
    AgentSeats.current.release(room, owner[:id])
  end
end
