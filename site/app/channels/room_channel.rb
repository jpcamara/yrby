# The shape demos' channel: yrby-rails' own Y::DocumentChannel, opened to
# the demo documents of any room. The page renders the document's grant with
# room.collaborative_document(demo).grant, so the client never names a
# document. RecordChannelGuard adds this site's seats and throttles (see
# config/initializers/record_channels.rb).
class RoomChannel < Y::DocumentChannel
  # The rooms are public. A valid grant shows this site rendered the page,
  # and for an anonymous demo that's enough. The block replaces the
  # example-only block that config/initializers/record_channels.rb sets.
  authorize_document { |record, name| record.is_a?(Room) && Demos.shape_slugs.include?(name) }
end
