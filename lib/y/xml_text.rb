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
  end
end
