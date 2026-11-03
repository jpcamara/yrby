# frozen_string_literal: true

module Y
  # `transact` for a document and each of its handles: run the block in one
  # write transaction on the document, so its writes commit together.
  #
  # Every handle call and read inside the block, from the block's fiber,
  # uses that transaction and sees the block's writes. A block already open
  # in this fiber is joined, not nested. Other threads and fibers wait for
  # the commit and never see the writes half done. The wait can be
  # interrupted, and under a fiber scheduler it yields. Without a scheduler,
  # a fiber the block resumes raises Y::Error instead of waiting.
  #
  # The writes commit when the block returns or raises. There is no rollback.
  # Applying a remote update inside the block raises Y::Error, since it needs
  # a transaction of its own. Keep the block short: everything else waits on
  # it.
  module Transact
    def transact
      raise ArgumentError, "transact needs a block" unless block_given?

      native_transact { yield self }
    end
  end

  # Ruby-side conveniences over the native document.
  class Doc
    include Transact

    # Runs the block in a transaction, like `transact`, and returns the update
    # its writes made, or nil when they changed nothing. The document has the
    # edit either way. The update is what a process saves and broadcasts, one
    # call per chunk as it streams into a document.
    #
    # The update is exactly the block's transaction. Another thread's or
    # fiber's write waits until the block returns, so it stays out.
    # `edit` raises Y::Error inside another `edit` or `transact` on the same
    # document, where the outer block's update would hold its writes.
    def edit
      raise ArgumentError, "edit needs a block" unless block_given?

      native_edit { yield self }
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

  [Map, Array, Text, XmlText].each { |handle| handle.include(Transact) }
end
