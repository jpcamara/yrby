# frozen_string_literal: true

# POST /docs/:id/cursors/guests. What can be answered at once is answered
# here, before the invite's stream opens: no key, or a party already in
# this room. Then the invite takes the agent's shape (see AgentInvite):
# a stream under Falcon, documents#cursor_guests under Puma.
class GuestPartyInvite
  def initialize
    @invite = AgentInvite.new(GuestParty, action: :cursor_guests, suffix: ":cursors")
  end

  def call(env)
    return reply(503, "Set TYPESAFE_API_KEY on the server before inviting guests.") unless GuestParty.available?

    request = ActionDispatch::Request.new(env)
    return reply(409, "The guests are already here.") if GuestParty.running?("#{request.path_parameters[:id]}:cursors")

    @invite.call(env)
  end

  private

  def reply(code, message)
    [code, { "content-type" => "application/json", "cache-control" => "no-store" }, [JSON.generate(error: message)]]
  end
end
