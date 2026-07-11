# frozen_string_literal: true

# Materializes a collaborative document as ActionText, server-side: replay
# the durable store into a Y::Doc, render the Rhino page's fragment with
# Y::Tiptap, upsert the Note. The live document is already durable — this
# derives the representation the REST of the app reads (search, mailers,
# plain views), so it runs on a schedule that follows the writes: every
# recorded change re-arms a short trailing debounce, and the render happens
# once the document goes quiet. No browser is involved; what persists can
# only be what the authoritative store says.
#
# The Save button on the Rhino page calls materialize directly — same code,
# user-triggered.
class NoteMaterializer
  DEBOUNCE_SECONDS = 1.0
  SWEEP_SECONDS = 0.25

  # Rhino's strike is its own "rhino-strike" mark serializing <del>; one
  # mark rule teaches the renderer (see the Rhino page).
  RENDER_RULES = { marks: { "rhino-strike" => { tag: "del" } } }.freeze

  @pending = Concurrent::Map.new
  @sweeper = nil
  @start_lock = Mutex.new

  class << self
    # Trailing-edge debounce: each change pushes the document's due time
    # out; the sweeper renders it once the due time passes with no newer
    # change. Called from the channel's on_change — it must NEVER raise (a
    # raise there rejects the change), so scheduling is just a map write.
    #
    # The sweeper is one thread per process, started lazily on first use and
    # restarted if dead — deliberately NOT Concurrent::ScheduledTask, whose
    # global timer thread is created during Rails boot and does not survive
    # Puma's cluster fork (tasks queue forever in workers, silently).
    def schedule(document_id)
      @pending[document_id] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEBOUNCE_SECONDS
      ensure_sweeper
    end

    # Replay -> render -> upsert. Returns the rendered HTML, or nil when the
    # document has nothing recorded or no "rhino" fragment (a doc that was
    # only ever edited through the other pages) — nothing to materialize.
    def materialize(document_id)
      update = Store.current.replay(document_id)
      return nil if update.nil?

      ydoc = Y::Doc.new
      ydoc.apply_update(update)
      html = Y::Tiptap.new(ydoc, **RENDER_RULES).to_html("rhino")
      return nil if html.nil?

      # create_or_find_by!: concurrent materializations of a fresh document
      # (each Puma worker sweeps its own connections' changes) both reach
      # here; the unique index turns the loser's INSERT into a find. The
      # rich-text row has its own uniqueness index, so the same race one
      # layer down gets one retry — by then the winner's row exists and the
      # save is an update. Content is last-write-wins either way: both
      # workers rendered the same authoritative store.
      note = Note.create_or_find_by!(document_id: document_id)
      begin
        note.content = html
        note.save!
      rescue ActiveRecord::RecordNotUnique
        note.reload
        note.content = html
        note.save!
      end
      html
    end

    private

    def ensure_sweeper
      return if @sweeper&.alive?

      @start_lock.synchronize do
        return if @sweeper&.alive?

        @sweeper = Thread.new do
          loop do
            sweep
            sleep SWEEP_SECONDS
          end
        end
      end
    end

    def sweep
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @pending.each_pair do |document_id, due|
        next if due > now
        # delete_pair is compare-and-delete: a change that re-armed the doc
        # after this read keeps its (newer) entry, and the next sweep gets it.
        next unless @pending.delete_pair(document_id, due)

        # Rails executor: safe ActiveRecord connection handling on a
        # non-Rails-managed thread.
        Rails.application.executor.wrap { materialize(document_id) }
      rescue StandardError => e
        Rails.logger.warn("[note_materializer] #{document_id}: #{e.class}: #{e.message}")
      end
    end
  end
end
