# The record behind the Lexxy demo. One Note per room, minted by
# the demo controller (find_or_create_by room id).
#
# has_collaborative_rich_text comes from lexxy-realtime's Collaborative
# concern. This app has no Action Text, so the concern's capability check
# (`has_rich_text(name) if respond_to?(:has_rich_text)`) leaves `body` a plain
# text column, and refresh_collaborative_rich_text writes the Y::Lexxy-rendered
# HTML straight into it. The CRDT state itself is a Y::Document row bound to
# this record (`record` + name "body"), created on first join and destroyed
# with the note.
class Note < ApplicationRecord
  include LexxyRealtime::Collaborative

  has_collaborative_rich_text :body

  # lexxy-realtime scopes its signed GlobalIDs by purpose,
  # LexxyRealtime.sgid_purpose(field) = "lexxy_realtime/<field>", so a token
  # minted for one field cannot join another. This demo keeps that scoping but
  # signs a ROOM id rather than a record id: the page must not mint a Note row
  # on a GET (a crawler could then create rows without bound), so there is no
  # record to build a GlobalID from at render time. The room token carries the
  # same field/purpose scope; NoteChannel verifies it and creates the Note on
  # subscribe, under the room budget (see DemosController#show, NoteChannel).
  def self.sgid_purpose(field) = "lexxy_realtime/#{field}"

  # A signed, field-scoped token for a room. The verifier is keyed by the
  # purpose (which embeds the field), so a token minted for :body verifies only
  # under :body: a token for one field cannot be replayed for another, the same
  # guarantee the gem's sgid gives, minus the pre-created row.
  def self.room_token(room, field)
    room_verifier(field).generate(room.to_s)
  end

  # The room a token was minted for, or nil when the token is missing, tampered,
  # minted for a different field/purpose, or carries a malformed room id.
  def self.verified_room(token, field)
    return nil unless token.is_a?(String)

    room = room_verifier(field).verified(token)
    room if room.is_a?(String) && Demos.valid_room?(room)
  end

  def self.room_verifier(field) = Rails.application.message_verifier(sgid_purpose(field))

  # The site accepts no uploads, and the editor has attachments disabled, but
  # a client that skips the page and speaks the protocol can still craft a
  # document containing attachment nodes (a data: URL in an attachment's url
  # attribute is a smuggled file). Y::Lexxy's default schema would render them
  # into the stored column, so materialization suppresses them: attachment
  # nodes render to nothing, text content survives. The gem's next release
  # adds a nodes: option on has_collaborative_rich_text that turns this
  # override back into a macro argument.
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
