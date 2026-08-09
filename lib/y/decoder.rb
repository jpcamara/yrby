# frozen_string_literal: true

require "y"

module Y
  # Plain-text reconstruction of a stored Yjs document, for search indexing
  # and previews. It reads the text out of the shared type the editor uses
  # (Lexical's `Y.XmlText`, plain `Y.Text`, or ProseMirror's `Y.XmlFragment`)
  # in-process, on the same native extension as `Doc`: no Node, no
  # subprocess.
  #
  #   state = doc.encode_state_as_update  # opaque CRDT bytes from the store
  #   Y::Decoder.text(state)              # => "hello world"
  #   Y::Decoder.preview(state, 280)      # => "hello world…"
  #
  # For full-fidelity HTML, `Y::Lexxy` and `Y::Tiptap` render the document
  # with the editor's own semantics; this module is the cheap plain-text
  # path.
  module Decoder
    class Error < Y::Error; end

    module_function

    # Plain text of the document. `field` pins the root key (Lexical: the editor
    # id; ProseMirror: "default"); omit it to use the document's sole root.
    def text(state, field: nil)
      field ||= Y::Doc.new.tap { |d| d.apply_update(state) }.root_names.first
      return "" unless field

      # A plain `Y.Text` root (a simple shared-text editor) reads straight out.
      # (A yrs root's type is fixed by its first typed access, so each reader
      # gets a fresh doc to try a different shared type against the same state.)
      direct = load(state).read_text(field)
      return normalize(direct) if direct && !direct.strip.empty?

      # Lexical (each block a sibling `Y.XmlText`) and ProseMirror (blocks are
      # `Y.XmlElement`s) both come back from read_xml as block-per-line markup;
      # strip any element tags to plain text.
      markup = load(state).read_xml(field)
      markup ? normalize(strip_tags(markup)) : ""
    end

    # A compact, single-line preview for list UIs.
    def preview(state, limit: 280, field: nil)
      body = text(state, field: field).gsub(/\s+/, " ").strip
      body.length > limit ? "#{body[0, limit].rstrip}…" : body
    end

    def load(state)
      Y::Doc.new.tap { |doc| doc.apply_update(state) }
    end

    def strip_tags(markup)
      markup.gsub(/<[^>]*>/, " ")
    end

    def normalize(text)
      text.gsub(/[ \t]+/, " ")     # collapse runs of spaces/tabs
          .gsub(/ *\n */, "\n")    # trim spaces left around block separators
          .gsub(/\n{3,}/, "\n\n")  # cap blank-line runs
          .strip
    end
  end
end
