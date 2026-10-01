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
    #   <yrby-document grant="<signed sgid>" name="body"></yrby-document>
    #
    # Importing "yrby-client/element" registers the element. It subscribes to
    # Y::DocumentChannel by itself and exposes the synced Y.Doc through its
    # `doc` property and `yrby:synced` event, much like the element behind
    # turbo_stream_from.
    #
    # The grant is a signed GlobalID scoped to this record and attribute
    # (record.collaborative_sgid(name)). Only render the tag on pages where
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
    # own authorization and renders { grant: record.collaborative_sgid(name) }:
    #
    #   <%= collaborative_document_tag @post, :body, expires_in: 10.minutes,
    #                                  refresh: grant_post_path(@post) %>
    module Helper
      def collaborative_document_tag(record, name, expires_in: nil, refresh: nil, **, &)
        grant = record.collaborative_sgid(name, **{ expires_in: expires_in }.compact)
        attributes = { grant: grant, name: name }
        attributes[:refresh] = refresh if refresh
        # The helper's attributes go last because a later key wins in a keyword
        # splat, so a template can't override the grant or the name.
        tag.yrby_document(**, **attributes, &)
      end
    end
  end
end
