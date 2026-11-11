# frozen_string_literal: true

module Y
  class Map
    # Store a new Y.Text holding `content` at `key`, replacing what was
    # there, and return a live Y::Text for it. `map[key] = "..."` stores a
    # plain string instead, and the last write to it wins.
    def set_text(key, content = "")
      native_set_text(key, content)
    end
  end
end
