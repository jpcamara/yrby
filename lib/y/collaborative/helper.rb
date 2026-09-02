# frozen_string_literal: true

module Y
  module Collaborative
    # The view side of a collaborative document, included into Action View by
    # the engine.
    #
    #   <%= collaborative_document_tag @post, :body %>
    #
    # renders a div carrying everything a client needs to join that one
    # document through the gem-shipped Y::DocumentChannel:
    #
    #   <div data-collaborative-document
    #        data-grant="<signed sgid>" data-name="body"
    #        data-channel="Y::DocumentChannel"></div>
    #
    # The grant is a signed GlobalID scoped to this record and attribute
    # (record.collaborative_sgid(name)) — the same idea as turbo_stream_from's
    # signed stream names. Render the tag only where the request is already
    # authorized to collaborate on the record; possession of the grant is what
    # the channel checks.
    #
    # Extra options pass through to the div (a block becomes its content), so
    # the tag can be the mount point an editor binds to:
    #
    #   <%= collaborative_document_tag @post, :body, id: "editor" %>
    module Helper
      def collaborative_document_tag(record, name, **options, &)
        data = {
          collaborative_document: true,
          grant: record.collaborative_sgid(name),
          name: name,
          channel: "Y::DocumentChannel"
        }.merge(options.delete(:data) || {})

        tag.div(**options, data: data, &)
      end
    end
  end
end
