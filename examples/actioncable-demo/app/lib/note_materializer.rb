# frozen_string_literal: true

# Renders a collaborative document as ActionText: replay the durable store
# into a Y::Doc, render the Rhino page's fragment with Y::Tiptap, and
# upsert the Note. The live document is already durable. The Note exists
# for the rest of the app (search, mailers, plain views); it is a cache
# over the authoritative store.
#
# It refreshes on read. `fresh` compares the note's stamp against the
# store's version and re-renders only when the store has changes the note
# has not seen. The version must be monotonic in visibility order for that
# compare to be sound. Each store's `version` method explains how it
# provides that, and why the Postgres one counts rows instead of taking
# MAX(id). There is no background job or timer, and a reader always gets
# current content. The render takes nothing from a browser.
#
# An app with push consumers (search indexing, webhooks) would call
# `materialize` from the channel's `on_change` instead, debounced. Don't
# raise there: a raise rejects the user's change.
#
# Nothing here is specific to Rhino. The pattern is one materializer per
# fragment and renderer: the Tiptap page would use `to_html("default")`
# with no mark rule, and the Lexxy page `Y::Lexxy.new(ydoc).to_html("root")`.
# The demo materializes one fragment because a real app has one editor.
class NoteMaterializer
  # Rhino's strike is its own "rhino-strike" mark serializing <del>; one
  # mark rule teaches the renderer (see the Rhino page).
  RENDER_RULES = { marks: { "rhino-strike" => { tag: "del" } } }.freeze

  class << self
    # The note for a document, re-rendered first if the store has changes
    # the note has not seen. Returns nil when there is nothing to
    # materialize: no recorded changes, or no "rhino" fragment (a document
    # only ever edited through the other pages).
    #
    # Only callers of this method get the freshness guarantee; loading Note
    # directly returns whatever was last rendered. Edits still in flight
    # are not in the store yet, so neither the version check nor the replay
    # sees them; they are picked up on the next read after they are
    # recorded.
    def fresh(document_id)
      version = Store.current.version(document_id)
      note = Note.find_by(document_id: document_id)
      return note if version.zero? || (note && note.through_version >= version)

      materialize(document_id, version) || note
    end

    # Replay -> render -> upsert, stamping the version the content was
    # rendered through. The version is read before the replay. If a change
    # lands in between, it gets rendered but not stamped, and the next read
    # re-renders. The stamp can understate what was rendered but never
    # overstate it, so content is never marked fresher than it is.
    def materialize(document_id, version = Store.current.version(document_id))
      update = Store.current.replay(document_id)
      return nil if update.nil?

      ydoc = Y::Doc.new
      ydoc.apply_update(update)
      html = Y::Tiptap.new(ydoc, **RENDER_RULES).to_html("rhino")
      return nil if html.nil?

      # Two concurrent readers can both find the note stale and render.
      # create_or_find_by! turns the loser's INSERT into a find via the
      # unique index. The rich-text row has its own uniqueness index with
      # the same race, so that save gets one retry; by then the winner's
      # row exists and the retry is an update. Last write wins, which is
      # fine because both readers rendered the same store.
      note = Note.create_or_find_by!(document_id: document_id)
      begin
        note.content = html
        note.through_version = version
        note.save!
      rescue ActiveRecord::RecordNotUnique
        note.reload
        note.content = html
        note.through_version = version
        note.save!
      end
      note
    end
  end
end
