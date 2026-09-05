# frozen_string_literal: true

module Y
  module Collaborative
    # The view side of a collaborative document, included into Action View by
    # the engine.
    #
    #   <%= collaborative_document_tag @post, :body %>
    #
    # renders the auto-connecting element:
    #
    #   <yrby-document grant="<signed sgid>" name="body"></yrby-document>
    #
    # Importing "yrby-client/element" registers it; it subscribes itself to
    # the gem-shipped Y::DocumentChannel (the way turbo_stream_from's element
    # subscribes itself to Turbo::StreamsChannel) and hands your code the
    # synced Y.Doc through its `doc` property and `yrby:synced` event.
    #
    # The grant is a signed GlobalID scoped to this record and attribute
    # (record.collaborative_sgid(name)). Render the tag only where the request
    # is already authorized to collaborate on the record; possession of the
    # grant is what the channel checks.
    #
    # Extra options pass through to the element (a block becomes its content),
    # so it can wrap the mount point an editor binds to:
    #
    #   <%= collaborative_document_tag @post, :body, id: "editor" %>
    module Helper
      def collaborative_document_tag(record, name, **, &)
        tag.yrby_document(**, grant: record.collaborative_sgid(name), name: name, &)
      end
    end
  end
end
