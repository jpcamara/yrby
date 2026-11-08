# frozen_string_literal: true

# The README's Rage channel. The hooks default to Y::Document storage.
class DocumentChannel < Rage::Cable::Channel
  include Y::Rage

  def subscribed = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data)

  private

  def authorized?(key) = !key.start_with?("denied")
end
