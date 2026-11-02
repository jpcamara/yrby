# frozen_string_literal: true

module Y
  module Collaborative
    # The view side of a collaborative document. The engine includes it into
    # Action View.
    #
    #   <%= collaborative_document_tag @post, :body %>
    #
    # renders the auto-connecting element:
    #
    #   <yrby-document channel="Y::DocumentChannel" grant="<signed grant>" name="body"></yrby-document>
    #
    # Importing "yrby-client/element" registers the element. It subscribes to
    # the document's channel by itself and exposes the synced Y.Doc through its
    # `doc` property and `yrby:synced` event, much like the element behind
    # turbo_stream_from.
    #
    # The grant and channel come from record.collaborative_document(name), so
    # the tag works for any gem that returns its own document, such as
    # lexxy-realtime. Pass channel: for an app's own Y::DocumentChannel
    # subclass. The grant is scoped to this record and attribute. Only render
    # the tag on pages where
    # the user may edit the record, because by default anyone holding the
    # grant can open the document. To also check the user's current
    # permissions when they subscribe, use Y::DocumentChannel.authorize_document.
    #
    # Extra options pass through to the element and a block becomes its
    # content, so the element can wrap the mount point an editor binds to:
    #
    #   <%= collaborative_document_tag @post, :body, id: "editor" %>
    #
    # expires_in: limits how long the grant lasts. refresh: is a URL the
    # element fetches a new grant from when a subscription is rejected, so it
    # can resubscribe without a page load. The app's action there re-runs its
    # own authorization and renders { grant: record.collaborative_document(name).grant }:
    #
    #   <%= collaborative_document_tag @post, :body, expires_in: 10.minutes,
    #                                  refresh: grant_post_path(@post) %>
    module Helper
      def collaborative_document_tag(record, name, expires_in: nil, refresh: nil, **, &)
        document = record.collaborative_document(name)
        attributes = { grant: document.grant(expires_in:), name: name }
        attributes[:refresh] = refresh if refresh
        # A later key wins in a keyword splat. A template can pass its own
        # channel, but it can't override the grant or the name.
        tag.yrby_document(channel: document.channel, **, **attributes, &)
      end
    end
  end
end
