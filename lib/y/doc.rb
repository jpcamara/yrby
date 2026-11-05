# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native document.
  class Doc
    # Runs the block, which edits this document through handles, and returns
    # an update with every local write no edit has returned yet, or nil when
    # there's nothing to send. The document has the writes either way. The
    # update is what a process saves and broadcasts, one call per chunk as it
    # streams into a document.
    #
    # The document keeps every local write until an edit returns it, so none
    # is left out: a write made outside an edit, from another thread or
    # fiber, or in a block that raised comes with the next edit's update. An
    # update applied from a peer is never in it, and doesn't wait for the
    # block. Each edit takes everything unsent at once, so the updates edits
    # return have no gaps between them. An edit inside another, including one
    # in a fiber or thread the outer block starts, returns what it took and
    # leaves it for the outer edit to return again. Once the outer edit
    # returns, a thread it started edits on its own.
    #
    # An exception raised as `edit` returns, such as a Thread#raise or a
    # signal trap, loses the update the edit took. A caller that must send
    # every update masks interrupts around `edit` and doesn't raise from a
    # trap.
    def edit
      # The edits running in this fiber, inherited by the fibers and threads
      # their blocks start. Each is `[doc]` until it ends, then empty.
      outer = (Fiber[:yrby_editing] || []).reject(&:empty?)
      nested = outer.any? { |running| running.include?(self) }
      running = [self]
      Fiber[:yrby_editing] = [*outer, running]
      begin
        yield self
      ensure
        running.clear
        Fiber[:yrby_editing] = outer
      end
      take_unsent(nested)
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

    private

    # An interrupt that arrives during the take is raised once the masked
    # block ends, and the taken update goes back to the document first, for
    # the next edit to return. A nested edit has already put it back.
    def take_unsent(nested)
      taken = nil
      Thread.handle_interrupt(Object => :never) do
        taken = native_take_unsent
        native_keep_unsent(taken) if taken && nested
      end
      taken
    rescue Exception # rubocop:disable Lint/RescueException -- an interrupt is any exception
      native_keep_unsent(taken) if taken && !nested
      raise
    end
  end
end
