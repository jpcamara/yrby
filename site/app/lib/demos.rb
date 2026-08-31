# The demo pages, in nav order.
#
# One list, read by the router, the controller, the views, and the channel's key
# validation, so a demo can't exist in the nav and not in the channel.
module Demos
  Demo = Data.define(:slug, :title, :shape, :blurb)

  ALL = [
    Demo.new(
      slug: "lexxy",
      title: "Rich text",
      shape: "Y.XmlFragment",
      blurb: "A Lexxy editor over lexxy-realtime; the server renders the document into the record's column as you type."
    ),
    Demo.new(
      slug: "tiptap",
      title: "Tiptap",
      shape: "Y.XmlFragment",
      blurb: "The same document shape through Tiptap's own Collaboration extension."
    ),
    Demo.new(
      slug: "spreadsheet",
      title: "Spreadsheet",
      shape: "Y.Array of row Y.Maps, cells nested",
      blurb: "Cell-level merges, plus sorting that stays out of the document."
    ),
    Demo.new(
      slug: "whiteboard",
      title: "Whiteboard",
      shape: "Y.Map",
      blurb: "Draggable notes as a map of records — the shape canvas tools keep."
    ),
    Demo.new(
      slug: "kanban",
      title: "Kanban",
      shape: "Y.Array",
      blurb: "Cards in a list, moved with a single map write so moves never conflict."
    ),
    Demo.new(
      slug: "codemirror",
      title: "Code",
      shape: "Y.Text",
      blurb: "CodeMirror 6 over a Y.Text, with remote cursors and selections."
    )
  ].freeze

  BY_SLUG = ALL.index_by(&:slug).freeze

  # Room ids are minted by the server (SecureRandom.urlsafe_base64), but people
  # type them too, so anything short and URL-shaped is allowed. The bound
  # matters: the key is what the store is keyed on, and an unbounded key space
  # is an unbounded number of rooms.
  ROOM_FORMAT = /\A[A-Za-z0-9_-]{1,32}\z/

  KEY_FORMAT = %r{\A(#{ALL.map { |d| Regexp.escape(d.slug) }.join("|")})/[A-Za-z0-9_-]{1,32}\z}

  class << self
    def find(slug) = BY_SLUG[slug.to_s]

    def slugs = BY_SLUG.keys

    def valid_room?(room) = ROOM_FORMAT.match?(room.to_s)

    # The store key for a room. Each demo keeps its own document, so the nav can
    # carry one room id across all of them without the Yjs shapes colliding.
    def document_key(slug, room) = "#{slug}/#{room}"

    def valid_key?(key) = KEY_FORMAT.match?(key.to_s)

    def new_room = SecureRandom.urlsafe_base64(8)
  end
end
