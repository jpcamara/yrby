# The pixel canvas's channel: DocumentChannel with one change. Updates are
# recorded through PixelDocument, which never compacts, so the update log is
# the full paint history the timelapse replays. The guards, the signed grant,
# and on_load are inherited unchanged.
class PixelChannel < DocumentChannel
  on_change { |key, update| PixelDocument.append(key, update) }
end
