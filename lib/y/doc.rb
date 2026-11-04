# frozen_string_literal: true

require "monitor"

module Y
  # Ruby-side conveniences over the native document.
  class Doc
    # Runs the block, which edits this document through handles, and returns
    # the update its writes produced, or nil when there's nothing to send.
    # The document has the edit either way. The update is what a process
    # saves and broadcasts, one call per chunk as it streams into a document.
    #
    # The document keeps every local write until an edit returns it, so none
    # is left out: a write made outside an edit, from another thread or
    # fiber, or in a block that raised comes with the next edit's update. An
    # update applied from a peer is never in it, and doesn't wait for the
    # block. Edits on one document run one at a time, so an edit's writes
    # take consecutive clocks. An edit inside another returns what it took,
    # and the outer edit returns it again.
    def edit
      edit_lock.synchronize do
        @edit_depth = (@edit_depth || 0) + 1
        begin
          yield self
          # An interrupt between taking the update and returning it would lose it.
          Thread.handle_interrupt(Object => :never) do
            update = native_take_unsent
            native_keep_unsent(update) if update && @edit_depth > 1
            update
          end
        ensure
          @edit_depth -= 1
        end
      end
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

    EDIT_LOCKS = Mutex.new
    private_constant :EDIT_LOCKS

    private

    def edit_lock = @edit_lock || EDIT_LOCKS.synchronize { @edit_lock ||= Monitor.new }
  end
end
