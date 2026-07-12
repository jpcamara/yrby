# frozen_string_literal: true

# The ActionText record for a collaborative Rhino document. The rich text
# is never taken from a client: NoteMaterializer replays the durable store
# into a Y::Doc and renders it with Y::Tiptap on read, so what persists
# comes from the authoritative CRDT. through_version is the store version
# the content was rendered through.
class Note < ApplicationRecord
  has_rich_text :content
end
