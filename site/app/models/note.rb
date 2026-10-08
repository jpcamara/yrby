# The record for the Lexxy demo. There's one Note per room, and NoteChannel
# creates it when the first client subscribes.
#
# has_collaborative_rich_text comes from lexxy-realtime's Collaborative
# concern. This app doesn't use Action Text, and the concern only calls
# `has_rich_text(name)` when the model responds to it, so `body` is a plain
# text column. After each update, the channel renders the document with
# Y::Lexxy and saves the HTML to it. The CRDT state is a Y::Document row tied
# to this record (`record` plus the name "body"). It's created by the first
# write and destroyed with the note.
class Note < ApplicationRecord
  include LexxyRealtime::Collaborative

  # The site doesn't accept uploads, and the editor has attachments turned off.
  # A client that skips the page and talks the protocol directly can still
  # build a document with attachment nodes, and a data: URL in an attachment's
  # url attribute is a file. Y::Lexxy's default schema would render those into
  # the stored column, so these rules render attachment nodes as nothing and
  # keep the text.
  SUPPRESSED_NODES = {
    "action_text_attachment" => ->(_node) { "" },
    "custom_action_text_attachment" => ->(_node) { "" },
    "image_gallery" => ->(_node) { "" }
  }.freeze

  has_collaborative_rich_text :body, nodes: SUPPRESSED_NODES

  # The grant the Lexxy page renders. lexxy-realtime's grant is a signed
  # GlobalID, which needs a saved record, and the page can't create a Note on
  # a GET (see DemosController#show). So this signs the room id instead.
  # Each field has its own verifier, so a token made for :body only verifies
  # under :body, the same scoping the gem's grant has.
  def self.room_token(room, field)
    room_verifier(field).generate(room.to_s)
  end

  # The room a token was made for. Returns nil when the token is missing,
  # edited, made for a different field, or has an invalid room id.
  def self.verified_room(token, field)
    return nil unless token.is_a?(String)

    room = room_verifier(field).verified(token)
    room if room.is_a?(String) && Demos.valid_room?(room)
  end

  def self.room_verifier(field) = Rails.application.message_verifier("note_rooms/#{field}")
end
