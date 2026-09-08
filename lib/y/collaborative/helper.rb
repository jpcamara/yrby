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
    # Importing "yrby-client/element" registers it. The element subscribes to
    # Y::DocumentChannel on its own and exposes the synced Y.Doc through its
    # `doc` property and `yrby:synced` event. It works like the element behind
    # turbo_stream_from.
    #
    # The grant is a signed GlobalID scoped to this record and attribute
    # (record.collaborative_sgid(name)). Render the tag only where the request
    # is already allowed to edit the record, because holding the grant is what
    # the channel checks by default. To also check the user's current
    # permissions when they subscribe, use Y::DocumentChannel.authorize_document.
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
