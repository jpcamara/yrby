# The demo pages, in nav order.
#
# The router, the controller, the views, and the channel's key validation all
# read this list, so a demo can't appear in the nav without the channel
# accepting it.
module Demos
  Demo = Data.define(:slug, :title, :shape, :blurb, :read)

  # How the server reads a demo's document without a browser: the root name
  # and its type. `kind` picks the Doc reader (read_text, read_xml, read_map,
  # or read_array). The Lexxy demo has no reader. It saves HTML to the
  # note.body column, and DemosController#body returns that.
  Reader = Data.define(:root, :kind)

  ALL = [
    Demo.new(
      slug: "lexxy",
      title: "Lexxy",
      shape: "Y.XmlText",
      blurb: "Basecamp's Lexxy editor. After each change, the server renders the document to HTML " \
             "and saves it to a record.",
      read: nil
    ),
    Demo.new(
      slug: "tiptap",
      title: "Tiptap",
      shape: "Y.XmlFragment",
      blurb: "Rich text with Tiptap's own collaboration extensions, including other people's cursors.",
      read: Reader.new(root: "default", kind: :xml)
    ),
    Demo.new(
      slug: "spreadsheet",
      title: "Spreadsheet",
      shape: "Y.Array of row Y.Maps",
      blurb: "Each cell is its own Y.Map, so edits to different cells merge. Each window sorts on its own.",
      read: Reader.new(root: "rows", kind: :array)
    ),
    Demo.new(
      slug: "whiteboard",
      title: "Whiteboard",
      shape: "Y.Map of Y.Maps",
      blurb: "Sticky notes you can add, drag, and edit together.",
      read: Reader.new(root: "shapes", kind: :map)
    ),
    Demo.new(
      slug: "kanban",
      title: "Kanban",
      shape: "Y.Array of Y.Maps",
      blurb: "Moving a card changes one field, so two people can move different cards at the same time.",
      read: Reader.new(root: "cards", kind: :array)
    ),
    Demo.new(
      slug: "codemirror",
      title: "Code",
      shape: "Y.Text",
      blurb: "CodeMirror 6 with y-codemirror.next, including other people's cursors and selections.",
      read: Reader.new(root: "code", kind: :text)
    )
  ].freeze

  BY_SLUG = ALL.index_by(&:slug).freeze

  # The server generates room ids with SecureRandom.urlsafe_base64, but people
  # type them too, so any short URL-safe string is allowed. The length limit
  # matters because documents are stored by key, and an unlimited set of keys
  # would allow an unlimited number of rooms.
  ROOM_FORMAT = /\A[A-Za-z0-9_-]{1,32}\z/

  KEY_FORMAT = %r{\A(#{ALL.map { |d| Regexp.escape(d.slug) }.join("|")})/[A-Za-z0-9_-]{1,32}\z}

  class << self
    def find(slug) = BY_SLUG[slug.to_s]

    def slugs = BY_SLUG.keys

    def valid_room?(room) = ROOM_FORMAT.match?(room.to_s)

    # The store key for a room. Each demo has its own document, so the nav can
    # use one room id for every demo without their Yjs data colliding.
    def document_key(slug, room) = "#{slug}/#{room}"

    def valid_key?(key) = KEY_FORMAT.match?(key.to_s)

    def new_room = SecureRandom.urlsafe_base64(8)

    # A signed token for a shape demo's document. It works like
    # Note.room_token does for the Lexxy demo. The page request checks the key
    # (a known demo and a well-formed room) and signs it. DocumentChannel only
    # accepts keys that verified_key returns, so a raw cable client can't open
    # a document the server never rendered a page for.
    def room_token(slug, room)
      verifier.generate(document_key(slug, room))
    end

    # The document key in a token, or nil when the token is missing, has been
    # tampered with, or names a key that isn't in the demo list.
    def verified_key(token)
      return nil unless token.is_a?(String)

      key = verifier.verified(token)
      key if key.is_a?(String) && valid_key?(key)
    end

    def verifier = Rails.application.message_verifier("demos/documents")

    # Rebuilds the document in Ruby from stored state for the server-side
    # read panel. `state` is the merged update from Y::Document.load_state,
    # or nil when the room has no document yet. read_text and read_xml return
    # a string, and read_map and read_array return a JSON string. The panel
    # shows the result as is.
    def read_stored(reader, state)
      return nil if state.nil?

      doc = Y::Doc.new
      doc.apply_update(state)
      case reader.kind
      when :text then doc.read_text(reader.root)
      when :xml then doc.read_xml(reader.root)
      when :map then doc.read_map(reader.root)
      when :array then doc.read_array(reader.root)
      end
    end
  end
end
