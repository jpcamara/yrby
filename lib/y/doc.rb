# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native document.
  class Doc
    # The update the block's writes produced, as one Yjs update, or nil when
    # it wrote nothing. It holds only what the block wrote through handles on
    # this thread: an update applied from elsewhere while it runs is not in
    # it. This is the unit a long-lived process records and broadcasts as it
    # streams into a document, one call per chunk.
    def diff
      recording = record_updates
      yield self
      recording.finish
    ensure
      recording&.finish
    end

    # The ordinal of the top-level block a position falls in, or nil at the
    # root or once the block is gone. Takes an `Anchor`, or a raw relative
    # position hash (`{type, tname, item, assoc}`, the shape editors put in
    # awareness as `anchorPos`/`focusPos`) plus the root's name.
    def block_at(position, root = nil)
      return native_block_at(position.position, position.root) if position.is_a?(Anchor)
      raise ArgumentError, "block_at needs the root name with a raw position" unless root

      native_block_at(position, root)
    end

    # The block an anchor names, as a live handle, or nil once it is gone.
    def find(anchor)
      native_find(anchor.position, anchor.root)
    end
  end
end
