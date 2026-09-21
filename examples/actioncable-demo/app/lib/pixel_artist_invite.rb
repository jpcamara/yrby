# frozen_string_literal: true

# Configuration errors are returned before opening a long-lived invite. The
# artist itself also guards against duplicate peers within this demo process.
class PixelArtistInvite
  # Falcon constructs the peer after opening its response stream. Carry the
  # invitation's cancellation generation through that delayed construction.
  Factory = Data.define(:stop_version) do
    def new(document_id, **) = PixelArtist.new(document_id, stop_version: stop_version, **)
  end

  def call(env)
    return reply(503, "Set a model API key on the server before inviting Ruby.") unless PixelArtist.available?

    request = ActionDispatch::Request.new(env)
    return reply(409, "Ruby is already painting in this room.") if PixelArtist.running?("#{request.path_parameters[:id]}:pixels")

    factory = Factory.new(stop_version: request.headers["X-Pixel-Stop-Version"].to_s)
    AgentInvite.new(factory, action: :pixel_artist, suffix: ":pixels").call(env)
  end

  private

  def reply(code, message)
    [code, { "content-type" => "application/json", "cache-control" => "no-store" }, [JSON.generate(error: message)]]
  end
end
