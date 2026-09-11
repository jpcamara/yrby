# frozen_string_literal: true

# A block's identity while other people edit. Handles address a block by its
# ordinal under the root, and a block someone inserts above moves every
# ordinal below it, so a handle held across a model call or a streamed write
# can drift onto the wrong block. An anchor is a relative position at the
# block's start: it gives the block's ordinal as of now, or nil once the
# block is gone.
class BlockAnchor
  def initialize(doc, block, root: "root")
    @doc = doc
    @root = root
    @position = block.relative_position(0, assoc: :after)
  end

  def ordinal
    @doc.block_at(@position, @root)
  end

  def block
    i = ordinal
    @doc.get_xml_text(@root).xml_text(i) if i
  end
end
