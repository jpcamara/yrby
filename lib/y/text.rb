# frozen_string_literal: true

module Y
  class Text
    # The Yjs relative position of `index`, the shape editors put in
    # awareness as a caret. It keeps pointing at the same character as
    # people edit around it. `assoc:` is :after (default) or :before.
    def relative_position(index, assoc: :after)
      native_relative_position(index, assoc.to_s)
    end

    # An anchor at `index` in this text, resolvable later with `Doc#index_at`.
    def anchor(index = 0)
      Anchor.new(position: relative_position(index), root: root_name)
    end
  end
end
