# frozen_string_literal: true

require "json"

module Y
  # A block's identity while other people edit. A handle addresses a block by
  # its ordinal under the root, and a block someone inserts above moves every
  # ordinal below it, so an ordinal held across a model call or a streamed
  # write can drift onto the wrong block. An anchor is the Yjs relative
  # position at the block's start plus the root's name. It is a plain value:
  # store it, send it, and ask the document where the block is now with
  # `Doc#block_at(anchor)` or fetch it with `Doc#find(anchor)`.
  #
  #   anchor = block.anchor
  #   doc.block_at(anchor)   # => 3 (the block's ordinal now), or nil once it is gone
  #   doc.find(anchor)       # => the live handle, or nil
  #   Y::Anchor.from_json(anchor.to_json) == anchor
  Anchor = Data.define(:position, :root) do
    def self.from_h(hash)
      hash = hash.transform_keys(&:to_s)
      new(position: hash.fetch("position").transform_keys(&:to_s), root: hash.fetch("root"))
    end

    def self.from_json(json)
      from_h(JSON.parse(json))
    end

    def to_h
      { "position" => position, "root" => root }
    end

    def to_json(*)
      to_h.to_json(*)
    end
  end
end
