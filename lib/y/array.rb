# frozen_string_literal: true

module Y
  # Inside module Y, `Array` is this class.
  class Array
    # Insert a new Y.Text holding `content` at `index` and return a live
    # Y::Text for it. Indexes work as in `insert`: -1 appends.
    def insert_text(index, content = "")
      native_insert_text(index, content)
    end

    # Append a new Y.Text holding `content` and return a live Y::Text for it.
    def push_text(content = "")
      insert_text(-1, content)
    end
  end
end
