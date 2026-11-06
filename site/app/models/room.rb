# A demo room. DemosController#start creates the row, and the room holds one
# collaborative document per demo, so one room link works for every demo in
# the nav.
#
# The Lexxy demo's document is a rich-text field. has_collaborative_rich_text
# comes from lexxy-realtime's Collaborative concern. This app doesn't use
# Action Text, and the concern only calls `has_rich_text(name)` when the
# model responds to it, so `body` is a plain text column. After each update,
# LexxyChannel renders the document with Y::Lexxy and saves the HTML to it.
# The shape demos' documents are plain yrby documents, one per demo, named
# after it.
#
# Each document is a Y::Document row tied to the room (`record` plus the
# name). It's created by its first write and destroyed with the room.
class Room < ApplicationRecord
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
  Demos.shape_slugs.each { |slug| has_collaborative_document slug }

  has_many :documents, class_name: "Y::Document", as: :record, dependent: :destroy
  has_many :seats, as: :room, dependent: :delete_all

  def to_param = slug
end
