# frozen_string_literal: true

# Materializes a collaborative document as ActionText, server-side: replay
# the durable store into a Y::Doc, render the Rhino page's fragment with
# Y::Tiptap, upsert the Note. The live document is already durable — the
# Note is a derived view for the REST of the app (search, mailers, plain
# views), which makes it a cache over the authoritative store.
#
# Caches can be lazy: `fresh` renders ON READ, and only when the store has
# recorded changes the note hasn't seen (one integer compare against the
# store's monotonic version). Nothing runs while documents are being edited,
# there is no background machinery, and a reader always gets current
# content. No browser is involved in the render either way; what persists
# can only be what the authoritative store says.
#
# An app with push consumers (search indexing, webhooks) would call
# `materialize` from the channel's `on_change` instead — debounced, and
# never raising (a raise there rejects the user's change).
#
# Nothing here is Rhino-specific: the pattern is per fragment + renderer.
# Materializing the Tiptap page is the same code with `to_html("default")`
# and no mark rule; the Lexxy page, `Y::Lexxy.new(ydoc).to_html("root")`.
# The demo materializes one fragment because a real app has one editor.
class NoteMaterializer
  # Rhino's strike is its own "rhino-strike" mark serializing <del>; one
  # mark rule teaches the renderer (see the Rhino page).
  RENDER_RULES = { marks: { "rhino-strike" => { tag: "del" } } }.freeze

  class << self
    # The note for a document, freshened if the store has moved past it.
    # Returns nil when there's nothing to materialize (no recorded changes,
    # or a document with no "rhino" fragment — one only ever edited through
    # the other pages).
    #
    # Freshness holds for readers who come THROUGH this method; loading
    # Note directly gets whatever was last stamped. Edits still in flight
    # (not yet recorded) are invisible to version and replay alike — the
    # next read after they're recorded picks them up.
    def fresh(document_id)
      version = Store.current.version(document_id)
      note = Note.find_by(document_id: document_id)
      return note if version.zero? || (note && note.through_version >= version)

      materialize(document_id, version) || note
    end

    # Replay -> render -> upsert, stamping the version the content was
    # rendered through. The version is read BEFORE the replay, so a change
    # racing in between gets rendered but not stamped — the next read
    # freshens again. Conservative, never stale-marked-fresh.
    def materialize(document_id, version = Store.current.version(document_id))
      update = Store.current.replay(document_id)
      return nil if update.nil?

      ydoc = Y::Doc.new
      ydoc.apply_update(update)
      html = Y::Tiptap.new(ydoc, **RENDER_RULES).to_html("rhino")
      return nil if html.nil?

      # create_or_find_by!: two concurrent readers can both find the note
      # stale and materialize; the unique index turns the loser's INSERT
      # into a find. The rich-text row has its own uniqueness index, so the
      # same race one layer down gets one retry — by then the winner's row
      # exists and the save is an update. Content is last-write-wins either
      # way: both readers rendered the same authoritative store.
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
