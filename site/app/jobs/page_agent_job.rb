require "y/agent"

# Runs one person's agent in a Lexxy room until it leaves. DemosController#agent
# takes the agent's seat before it enqueues this, and the job gives it back.
class PageAgentJob < ActiveJob::Base
  # The agent joins with the room's Lexxy document, which brings its grant
  # and LexxyChannel. `origin` is the site's origin as the inviting browser
  # saw it. The agent joins the cable there, unless AGENT_CABLE_URL names
  # another way in. It sends `origin` as its Origin either way, because the
  # cable checks it like a browser's and an internal URL wouldn't match.
  #
  # Each person in a room can bring one agent. The seat is that agent's
  # lock: a row the controller took, in the database every process shares,
  # so the job passes no lock of its own. AgentSeats also caps how many
  # agents a room and the site take.
  def perform(room, origin, owner)
    owner = owner.symbolize_keys
    url = ENV.fetch("AGENT_CABLE_URL") { "#{origin.sub(/\Ahttp/, "ws")}/cable" }
    document = Room.find_by!(slug: room).collaborative_document(:body)
    PageAgent.run(document, owner: PageAgent::Owner.new(**owner), url: url, lock: nil,
                            headers: { "Origin" => origin }, idle: Limits::AGENT_IDLE, max_stay: Limits::AGENT_MAX_STAY)
  ensure
    AgentSeats.current.release(room, owner[:id])
  end
end
