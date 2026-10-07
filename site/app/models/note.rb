# The record for the Lexxy demo. There's one Note per room, and NoteChannel
# creates it when the first client subscribes.
#
# has_collaborative_rich_text comes from lexxy-realtime's Collaborative
# concern. This app doesn't use Action Text, and the concern only calls
# `has_rich_text(name)` when the model responds to it, so `body` is a plain
# text column. refresh_collaborative_rich_text writes the HTML that Y::Lexxy
# renders directly into it. The CRDT state is a Y::Document row tied to this
# record (`record` plus the name "body"). It's created on the first join and
# destroyed with the note.
class Note < ApplicationRecord
  include LexxyRealtime::Collaborative

  has_collaborative_rich_text :body

  # lexxy-realtime gives its signed GlobalIDs a purpose per field,
  # LexxyRealtime.sgid_purpose(field) = "lexxy_realtime/<field>", so a token
  # made for one field can't join another. This demo keeps that scoping but
  # signs a room id instead of a record id. The page can't create a Note row
  # on a GET, because a crawler could then create rows without limit. So at
  # render time there's no record to build a GlobalID from. The room token
  # uses the same per-field purpose. NoteChannel verifies it and creates the
  # Note on subscribe, within the room budget (see DemosController#show and
  # NoteChannel).
  def self.sgid_purpose(field) = "lexxy_realtime/#{field}"

  # A signed token for a room, scoped to one field. The verifier is keyed by the
  # purpose, which includes the field, so a token made for :body only verifies
  # under :body and can't be reused for another field. The gem's sgid gives the
  # same guarantee, but it needs a row created first.
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

  def self.room_verifier(field) = Rails.application.message_verifier(sgid_purpose(field))

  # The site doesn't accept uploads, and the editor has attachments turned off.
  # A client that skips the page and talks the protocol directly can still
  # build a document with attachment nodes, and a data: URL in an attachment's
  # url attribute is a file. Y::Lexxy's default schema would render those into
  # the stored column, so this app renders attachment nodes as nothing and
  # keeps the text. When lexxy-realtime adds a nodes: option to
  # has_collaborative_rich_text, this override can move into the macro call.
  SUPPRESSED_NODES = {
    "action_text_attachment" => ->(_node) { "" },
    "custom_action_text_attachment" => ->(_node) { "" },
    "image_gallery" => ->(_node) { "" }
  }.freeze

  def refresh_collaborative_rich_text(name)
    raise ArgumentError, "#{name.inspect} is not collaborative" unless name.to_sym == :body

    document = collaborative_document(:body)
    return false unless document

    with_lock do
      state = document.reload.load_state
      break false if state.nil?

      doc = Y::Doc.new
      doc.apply_update(state)
      html = Y::Lexxy.new(doc, nodes: SUPPRESSED_NODES).to_html
      break false if html.nil?

      self.body = html
      save!(validate: false)
      true
    end
  end
end
