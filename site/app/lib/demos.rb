# The demo pages, in nav order.
#
# The router, the controller, the views, Room's documents, and RoomChannel
# all read this list, so a demo can't appear in the nav without a document
# and a channel that opens it.
module Demos
  Demo = Data.define(:slug, :title, :shape, :blurb, :read)

  # How the server reads a demo's document without a browser: the root name
  # and its type. `kind` picks the Doc reader (read_text, read_xml, read_map,
  # or read_array). The Lexxy demo has no reader. It saves HTML to room.body,
  # an Action Text field, and DemosController#body returns that.
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
      slug: "chat",
      title: "Chat",
      shape: "Y.Array of Y.Maps",
      blurb: "Messages with reactions. Everyone sees who is typing, and a message shows up only when it's sent.",
      read: Reader.new(root: "messages", kind: :array)
    ),
    Demo.new(
      slug: "codemirror",
      title: "Code",
      shape: "Y.Text",
      blurb: "CodeMirror 6 with y-codemirror.next, including other people's cursors and selections.",
      read: Reader.new(root: "code", kind: :text)
    ),
    Demo.new(
      slug: "form",
      title: "Form",
      shape: "Y.Map of Y.Texts",
      blurb: "Each text field is a Y.Text, so two people typing in the same field both keep their edit. " \
             "A choice is a plain value, and the last pick wins.",
      read: Reader.new(root: "form", kind: :map)
    )
  ].freeze

  BY_SLUG = ALL.index_by(&:slug).freeze

  # The server generates room ids with SecureRandom.urlsafe_base64, but people
  # type them too, so any short URL-safe string is allowed.
  ROOM_FORMAT = /\A[A-Za-z0-9_-]{1,32}\z/

  class << self
    def find(slug) = BY_SLUG[slug.to_s]

    def slugs = BY_SLUG.keys

    # The demos whose documents are plain yrby documents. The Lexxy demo's is
    # a rich-text field.
    def shape_slugs = slugs - ["lexxy"]

    # The Room field that holds a demo's document.
    def field(demo) = demo.slug == "lexxy" ? "body" : demo.slug

    def valid_room?(room) = ROOM_FORMAT.match?(room.to_s)

    def new_room = SecureRandom.urlsafe_base64(8)

    # Rebuilds the document in Ruby from stored state for the server-side
    # read panel. `state` is the merged update from the document's load_state,
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
