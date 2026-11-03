# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native document.
  class Doc
    # Runs the block, which edits this document through handles, and returns
    # the update its writes produced, or nil when the document didn't change.
    # The document has the edit either way. The update is what a process
    # saves and broadcasts, one call per chunk as it streams into a document.
    #
    # The update holds everything the document gained while the block ran,
    # so a write another thread or peer made meanwhile is in it too. Applying
    # an update twice changes nothing, so that only adds bytes.
    def edit
      before = native_snapshot
      yield self
      native_update_since(before)
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
