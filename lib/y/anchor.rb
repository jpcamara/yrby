# frozen_string_literal: true

require "json"

module Y
  # A block's identity as a plain value. A live handle already stays on its
  # block while people edit, but it lives in one process; an anchor can be
  # stored and sent, then turned back into the block's ordinal with
  # `Doc#block_at(anchor)` or into a handle with `Doc#find(anchor)`. It is a
  # Yjs relative position that names the block itself, plus the root's name.
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
