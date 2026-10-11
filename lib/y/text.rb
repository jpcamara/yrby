# frozen_string_literal: true

module Y
  class Text
    # The Yjs relative position of character `index`, the shape editors put
    # in awareness as a caret. It keeps pointing at the same character as
    # people edit around it; `index_at` says where that is now. `assoc:` is
    # :after (default) or :before.
    def relative_position(index, assoc: :after)
      native_relative_position(index, assoc.to_s)
    end
  end
end
