# frozen_string_literal: true

# Renders a collaborative document as ActionText: replay the durable store
# into a Y::Doc, render one fragment with its renderer, and upsert the Note
# for that document and fragment. The live document is already durable. The
# Note exists for the rest of the app (search, mailers, plain views); it is
# a cache over the authoritative store.
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
class NoteMaterializer
  # The Rhino page writes the "rhino" fragment. Rhino replaces Tiptap's
  # Strike with its own "rhino-strike" mark and serializes it as <del>; the
  # mark rule reproduces that (the stored name came from node_types
  # discovery).
  def self.render_rhino(ydoc)
    Y::Tiptap.new(ydoc, marks: { "rhino-strike" => { tag: "del" } }).to_html("rhino")
  end

  # The Lexxy page writes the "root" fragment (Lexical's default root name).
  def self.render_root(ydoc)
    Y::Lexxy.new(ydoc).to_html("root")
  end

  # Each materialized fragment and its renderer. Another page's fragment is
  # one more entry here plus a `fresh` call in its controller action.
  FRAGMENTS = {
    "rhino" => method(:render_rhino),
    "root" => method(:render_root)
  }.freeze

  class << self
    # The note for a document and fragment, re-rendered first if the store
    # has changes the note has not seen. Returns nil when there is nothing
    # to materialize: no recorded changes, or the document has no such
    # fragment (it was only ever edited through other pages).
    #
    # Only callers of this method get the freshness guarantee; loading Note
    # directly returns whatever was last rendered. Edits still in flight
    # are not in the store yet, so neither the version check nor the replay
    # sees them; they are picked up on the next read after they are
    # recorded.
    def fresh(document_id, fragment)
      version = Store.current.version(document_id)
      note = Note.find_by(document_id: document_id, fragment: fragment)
      return note if version.zero? || (note && note.through_version >= version)

      materialize(document_id, fragment, version) || note
    end

    # Replay -> render -> upsert, stamping the version the content was
    # rendered through. The version is read before the replay. If a change
    # lands in between, it gets rendered but not stamped, and the next read
    # re-renders. The stamp can understate what was rendered but never
    # overstate it, so content is never marked fresher than it is.
    def materialize(document_id, fragment, version = Store.current.version(document_id))
      render = FRAGMENTS.fetch(fragment)
      update = Store.current.replay(document_id)
      return nil if update.nil?

      ydoc = Y::Doc.new
      ydoc.apply_update(update)
      html = render.call(ydoc)
      return nil if html.nil?

      # Two concurrent readers can both find the note stale and render.
      # create_or_find_by! turns the loser's INSERT into a find via the
      # unique index. The rich-text row has its own uniqueness index with
      # the same race, so that save gets one retry; by then the winner's
      # row exists and the retry is an update. Last write wins, which is
      # fine because both readers rendered the same store.
      note = Note.create_or_find_by!(document_id: document_id, fragment: fragment)
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
