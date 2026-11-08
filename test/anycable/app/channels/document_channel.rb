# frozen_string_literal: true

# The README's AnyCable channel. The hooks default to Y::Document storage.
class DocumentChannel < Y::AnyCable::Channel
  def subscribed = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])

  def unsubscribed
    logger.info("unsubscribed #{params[:id]}")
  end

  private

  # "private-" documents are only for alice, which checks that the
  # connection's identifiers reach the channel on every RPC call.
  def authorized?(key)
    return identifiers["user"] == "alice" if key.start_with?("private-")

    !key.start_with?("denied")
  end
end
