# The demo pages, in nav order.
#
# One list, read by the router, the controller, the views, and the channel's key
# validation, so a demo can't exist in the nav and not in the channel.
module Demos
  Demo = Data.define(:slug, :title, :shape, :blurb, :read)

  # How the server reads a demo's document back with no browser: the root name
  # and its shape. `kind` maps straight to a Doc reader (read_text/read_xml/
  # read_map/read_array). The Rich text demo has no reader here — it stores a
  # materialized note.body column and is read through DemosController#body.
  Reader = Data.define(:root, :kind)

  ALL = [
    Demo.new(
      slug: "lexxy",
      title: "Rich text",
      shape: "Y.XmlFragment",
      blurb: "A Lexxy editor over lexxy-realtime; the server renders the document into the record's column as you type.",
      read: nil
    ),
    Demo.new(
      slug: "tiptap",
      title: "Tiptap",
      shape: "Y.XmlFragment",
      blurb: "The same document shape through Tiptap's own Collaboration extension.",
      read: Reader.new(root: "default", kind: :xml)
    ),
    Demo.new(
      slug: "spreadsheet",
      title: "Spreadsheet",
      shape: "Y.Array of row Y.Maps, cells nested",
      blurb: "Cell-level merges, plus sorting that stays out of the document.",
      read: Reader.new(root: "rows", kind: :array)
    ),
    Demo.new(
      slug: "whiteboard",
      title: "Whiteboard",
      shape: "Y.Map",
      blurb: "Draggable notes as a map of records — the shape canvas tools keep.",
      read: Reader.new(root: "shapes", kind: :map)
    ),
    Demo.new(
      slug: "kanban",
      title: "Kanban",
      shape: "Y.Array",
      blurb: "Cards in a list, moved with a single map write so moves never conflict.",
      read: Reader.new(root: "cards", kind: :array)
    ),
    Demo.new(
      slug: "codemirror",
      title: "Code",
      shape: "Y.Text",
      blurb: "CodeMirror 6 over a Y.Text, with remote cursors and selections.",
      read: Reader.new(root: "code", kind: :text)
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

    # The signed grant for a shape demo's document — the same access model the
    # Rich text demo gets from Note.room_token, generalized. The page GET is
    # where a key is judged (known demo, well-formed room) and the token is the
    # proof: DocumentChannel accepts only what verified_key returns, so a raw
    # cable client cannot name a document the server never rendered a page for.
    def room_token(slug, room)
      verifier.generate(document_key(slug, room))
    end

    # The document key a token grants, or nil when the token is missing,
    # tampered, or carries a key that no longer matches the demo list.
    def verified_key(token)
      return nil unless token.is_a?(String)

      key = verifier.verified(token)
      key if key.is_a?(String) && valid_key?(key)
    end

    def verifier = Rails.application.message_verifier("demos/documents")

    # The document reconstructed in Ruby from stored state — the server-side
    # read the "no browser in the loop" panel shows. `state` is the merged
    # update from Y::Document.load_state; nil means the room has no document
    # yet. read_text/read_xml return a string, read_map/read_array a JSON
    # string; either way the panel renders it verbatim.
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
