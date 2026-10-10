# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native live handle.
  class XmlText
    # The Yjs relative position of `index`: the `{type, tname, item, assoc}`
    # hash editors carry in awareness as `anchorPos`/`focusPos`. `assoc:` is
    # `:after` (the default) or `:before`.
    def relative_position(index, assoc: :after)
      native_relative_position(index, assoc.to_s)
    end

    # This block's `Anchor`: its start as a relative position, with the root's
    # name, so the document can say where the block is later. Works on an
    # empty block too, where the position names the block itself.
    def anchor
      Anchor.new(position: relative_position(0), root: root_name)
    end
  end
end
