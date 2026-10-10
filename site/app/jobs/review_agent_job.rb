require "y/agent"

# Runs the demo agent in a Lexxy room until it leaves. DemosController#agent
# takes the room's seat before it enqueues this, and the job gives it back.
class ReviewAgentJob < ActiveJob::Base
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
  def perform(room, origin)
    url = ENV.fetch("AGENT_CABLE_URL") { "#{origin.sub(/\Ahttp/, "ws")}/cable" }
    Y::Agent.run(RoomDocument.new(room), url: url, channel: "NoteChannel",
                                         headers: { "Origin" => origin },
                                         presence: ReviewAgent::IDENTITY.merge("focusing" => false),
                                         idle: Limits::AGENT_IDLE, max_stay: Limits::AGENT_MAX_STAY) do |agent|
      ReviewAgent.new(agent).start
    end
  ensure
    AgentSeats.current.release(room)
  end
end
