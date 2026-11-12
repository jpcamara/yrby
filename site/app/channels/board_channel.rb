# The agent board's channel: yrby-rails' Y::DocumentChannel, opened to each
# room's board document. RecordChannelGuard adds this site's seats and
# throttles, as it does for RoomChannel.
class BoardChannel < Y::DocumentChannel
  authorize_document { |record, name| record.is_a?(Room) && name == "board" }
end
