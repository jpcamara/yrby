# The pixel canvas's document: Y::Document with compaction off. Every paint
# stays a row in y_document_updates, so the timelapse can replay the whole
# history from the table. The other demos compact their tail every 64 rows
# and keep only the merged state.
#
# Same table, same rows; only the class attribute differs, so a load through
# Y::Document (the channel's on_load, the sweeper, the stored panel) sees the
# same document. The room's byte cap (Limits::MAX_DOCUMENT_BYTES) bounds the
# log at about 20,000 paints, after which the room is read-only like any other.
class PixelDocument < Y::Document
  self.compact_every = Float::INFINITY
end
