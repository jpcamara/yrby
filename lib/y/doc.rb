# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native document.
  class Doc
    # The update the block produced: everything added to the document while it
    # ran, encoded as a diff against the state before. Returns nil when the
    # block changed nothing. This is the unit a long-lived process records and
    # broadcasts as it streams into a document, one call per chunk.
    def diff
      before = encode_state_vector
      yield self
      update = encode_state_as_update(before)
      update.bytesize > 2 ? update : nil
    end
  end
end
