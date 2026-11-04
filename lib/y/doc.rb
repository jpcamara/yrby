# frozen_string_literal: true

require "monitor"

module Y
  # Ruby-side conveniences over the native document.
  class Doc
    # Runs the block, which edits this document through handles, and returns
    # the update its writes produced, or nil when they changed nothing. The
    # document has the edit either way. The update is what a process saves
    # and broadcasts, one call per chunk as it streams into a document.
    #
    # The update holds only the writes this block made, in this fiber. An
    # update applied from a peer meanwhile stays out of it and doesn't wait
    # for the block. Edits on one document run one at a time, so each edit's
    # writes take consecutive clocks and its update has no gaps for a peer
    # to wait on. An edit inside another adds its writes to the outer one.
    def edit
      edit_lock.synchronize do
        edits = Thread.current[:yrby_edits] ||= [] # fiber-local, as Thread#[] is
        edits.push(updates = [])
        begin
          yield self
          native_merge(updates) unless updates.empty?
        ensure
          edits.pop
          edits.last&.concat(updates)
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
