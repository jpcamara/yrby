# The Lexxy demo's channel: lexxy-realtime's own channel, which saves each
# update and then renders room.body from the whole document.
# config/lexxy_realtime.rb names it as the channel for rich-text fields, so
# collaborative_document_tag(room, :body) renders it. RecordChannelGuard adds
# this site's seats and throttles (see config/initializers/record_channels.rb).
class LexxyChannel < LexxyRealtime::DocumentChannel
  # The rooms are public. A valid grant shows this site rendered the page,
  # and for an anonymous demo that's enough. The parent's authorized? still
  # rejects a field that isn't declared with has_collaborative_rich_text.
  authorize_document { |record, _name| record.is_a?(Room) }
end
