# frozen_string_literal: true

# The ActionText landing spot for a collaborative Rhino document. The rich
# text is never taken from the client: DocumentsController#rhino_save replays
# the durable store into a Y::Doc and renders it with Y::Tiptap, so what
# persists is derived from the authoritative CRDT.
class Note < ApplicationRecord
  has_rich_text :content
end
