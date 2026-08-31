# The record behind the Rich text (Lexxy) demo. One Note per room, minted by
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

  # The signed-GlobalID purpose lexxy-realtime scopes its tokens with:
  # LexxyRealtime.sgid_purpose(field) = "lexxy_realtime/<field>". Mirrored
  # here because the gem's main module rides in its engine, which this app
  # cannot load (see the Gemfile); the format is the gem's public contract —
  # a token minted for another purpose or another field does not locate the
  # record, so a body token cannot join anything else.
  def self.sgid_purpose(field) = "lexxy_realtime/#{field}"

  def body_sgid = to_sgid(for: self.class.sgid_purpose(:body)).to_s

  # The site accepts no uploads, and the editor has attachments disabled — but
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
