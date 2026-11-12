require "y/agent"

# Runs one person's agent on a board until it leaves, like PageAgentJob does
# on the Lexxy page. BoardsController#agent takes the seat, and this gives it
# back.
class BoardAgentJob < ActiveJob::Base
  def perform(room, origin, owner)
    owner = owner.symbolize_keys
    url = ENV.fetch("AGENT_CABLE_URL") { "#{origin.sub(/\Ahttp/, "ws")}/cable" }
    document = Room.find_by!(slug: room).collaborative_document(:board)
    BoardAgent.run(document, owner: PageAgent::Owner.new(**owner), url: url, lock: nil,
                             headers: { "Origin" => origin }, idle: Limits::AGENT_IDLE, max_stay: Limits::AGENT_MAX_STAY)
  ensure
    AgentSeats.current.release(BoardsController.seat(room), owner[:id])
  end
end
