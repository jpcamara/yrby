# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native document.
  class Doc
    # The update the block produced: everything added to the document while it
    # ran, encoded as a diff against the state before. Returns nil when the
    # block changed nothing. This is the unit a long-lived process records and
    # broadcasts as it streams into a document, one call per chunk.
    def diff
      before = encode_state_vector
      yield self
      update = encode_state_as_update(before)
      update.bytesize > 2 ? update : nil
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

    # The block an anchor points at, as a live handle, or nil once it is gone.
    def find(anchor)
      ordinal = block_at(anchor)
      get_xml_text(anchor.root).xml_text(ordinal) if ordinal
    end
  end
end
