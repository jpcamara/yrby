# frozen_string_literal: true

# The ActionText record for one fragment of a collaborative document
# ("rhino" on the Rhino page, "root" on the Lexxy page). The rich text is
# never taken from a client: NoteMaterializer replays the durable store
# into a Y::Doc and renders the fragment on read, so what persists comes
# from the authoritative CRDT. through_version is the store version the
# content was rendered through.
class Note < ApplicationRecord
  has_rich_text :content
end
