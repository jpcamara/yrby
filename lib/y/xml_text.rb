# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native live handle.
  class XmlText
    # The Yjs relative position of character `index`: the `{type, tname,
    # item, assoc}` hash editors carry in awareness as `anchorPos`/`focusPos`.
    # `assoc:` is `:after` (the default) or `:before`.
    def relative_position(index, assoc: :after)
      native_relative_position(index, assoc.to_s)
    end

    # This block's `Anchor`: a value that names the block itself, with the
    # root's name, so the document can say where the block is later.
    def anchor
      Anchor.new(position: native_block_position, root: root_name)
    end
  end
end
