require "y/agent"

# Runs one person's agent on a room's agent sheet until it leaves. Like
# PageAgentJob, but with the room's sheet document and SheetAgent.
# DemosController#agent takes the seat before it enqueues this, and the job
# gives it back.
class SheetAgentJob < ActiveJob::Base
  def perform(room, origin, owner)
    owner = owner.symbolize_keys
    url = ENV.fetch("AGENT_CABLE_URL") { "#{origin.sub(/\Ahttp/, "ws")}/cable" }
    document = Room.find_by!(slug: room).collaborative_document(:sheet)
    SheetAgent.run(document, owner: SheetAgent::Owner.new(**owner), url: url, lock: nil,
                             headers: { "Origin" => origin }, idle: Limits::AGENT_IDLE, max_stay: Limits::AGENT_MAX_STAY)
  ensure
    AgentSeats.current.release(room, owner[:id])
  end
end
