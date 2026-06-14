# frozen_string_literal: true

require "json"

module YrbLite
  # Extract ProseMirror/Tiptap editor content from Y.Doc data without JavaScript.
  #
  # The conversion runs natively inside the Rust extension (yrs), reading the
  # same CRDT structures that y-prosemirror reads in the browser. See
  # docs/PROSEMIRROR.md and docs/ACCURACY.md for the research behind the mapping.
  class ProseMirrorExtractor
    # Extract a ProseMirror document from a binary Y.Doc update.
    #
    # @param update [String] binary V1 update (e.g. from Y.encodeStateAsUpdate)
    # @param fragment [String, nil] XML fragment name; defaults to trying
    #   "prosemirror", "default", then "doc"
    # @return [Hash] ProseMirror document JSON ({"type" => "doc", "content" => [...]})
    # @raise [YrbLite::Error] if the update can't be decoded or no fragment is found
    def self.extract(update, fragment: nil)
      JSON.parse(YrbLite.extract_prosemirror_json(update, fragment))
    end

    # Extract a ProseMirror document from a YrbLite::Doc.
    #
    # @param doc [YrbLite::Doc]
    # @param fragment [String, nil] XML fragment name (see .extract)
    # @return [Hash] ProseMirror document JSON
    def self.extract_from_doc(doc, fragment: nil)
      JSON.parse(doc.prosemirror_json(fragment))
    end
  end
end
