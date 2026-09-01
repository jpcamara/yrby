# Deletes stale documents from the store.
#
# With SQLite behind the channel, eviction is no longer about memory — an idle
# room costs a few rows on disk and nothing in RAM. What it is about now is
# content: these are public, anonymous, unmoderated documents, and "temporary"
# is a promise the site makes about them. The TTL is that promise. A room
# untouched for ROOM_IDLE_TTL is deleted, rows and all.
#
# "Untouched" means no write and no compaction inside the TTL: appends stamp
# y_document_updates.created_at and compaction stamps y_documents.updated_at,
# so a document is stale only when both are old. Occupied rooms are never
# evicted, however quiet — someone is looking at them.
#
# One plain Ruby thread in the server process, started once at boot. It does
# nothing but sleep between sweeps; under Falcon it runs alongside the fiber
# reactor, and a sleeping thread is free either way.
module RoomSweeper
  class << self
    def start(interval: Limits::SWEEP_INTERVAL)
      return @thread if @thread&.alive?

      @thread = Thread.new do
        Thread.current.name = "room-sweeper"
        loop do
          sleep interval
          run_once
        end
      end
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    def run_once(rooms: Rooms.current, ttl: Limits::ROOM_IDLE_TTL)
      evicted = sweep_documents(rooms, ttl)
      evicted.concat(sweep_notes(Time.current - ttl))
      Rails.logger.info("room-sweeper: evicted #{evicted.length} stale room(s)") if evicted.any?
      reap_leaked_connections
      evicted
    rescue StandardError => e
      # A sweep failure must never take the thread down with it; the next tick
      # tries again.
      Rails.logger.error("room-sweeper: #{e.class}: #{e.message}")
      # The connection reap is the caps' only leak backstop; a failure in the
      # room sweep above must not skip it, so run it in its own rescue.
      reap_leaked_connections
      []
    end

    # Delete stale documents without racing a join or a write.
    #
    # `occupied_keys` was a snapshot: a join or an append could commit between
    # selecting the stale set and destroying it, deleting a document out from
    # under a live session (and cascading to update rows written in that window).
    # So eviction is now a claim. The stale set is only a *candidate* list; the
    # room bookkeeping decides, atomically with its seat check, which candidates
    # have no occupant and no reservation, and marks them evicting — after which
    # a racing join is refused (:evicting) and a racing write can't re-open them.
    # We then re-read the database for the claimed keys (a write that landed
    # after the candidate query but before the claim leaves a fresh update row)
    # and delete only those still stale, dropping the mark on every claimed key.
    def sweep_documents(rooms, ttl)
      cutoff = Time.current - ttl
      candidates = stale_document_keys(cutoff, exclude: rooms.occupied_keys)
      claimed = rooms.claim_evictions(candidates)
      return [] if claimed.empty?

      begin
        # Under the claim no new join or write can touch these keys, so this
        # freshness re-read is stable: it only catches writes that slipped in
        # before the claim.
        evictable = stale_document_keys(cutoff, only: claimed)
        # destroy_all, not delete_all: Y::Document owns its update rows
        # (dependent: :delete_all), and destroying through the model keeps that
        # in one place.
        Y::Document.where(key: evictable).destroy_all if evictable.any?
        evictable
      ensure
        # Drop the evicting mark on every claimed key — deleted ones and the
        # ones the freshness re-read spared alike, so a spared room is joinable
        # again.
        claimed.each { |key| rooms.forget(key) }
      end
    end

    # Keys whose document is stale: no compaction (updated_at) and no append
    # (a fresh update row) inside the TTL. `exclude` drops occupied rooms from
    # the candidate pass; `only` narrows to the claimed keys for the freshness
    # re-read.
    def stale_document_keys(cutoff, exclude: nil, only: nil)
      scope = Y::Document.where(updated_at: ...cutoff)
                         .where.not(id: Y::DocumentUpdate.where(created_at: cutoff..).select(:document_id))
      scope = scope.where(key: only) if only
      scope = scope.where.not(key: exclude) if exclude&.any?
      scope.pluck(:key)
    end

    # Reap connections whose Disconnect RPC never fired, on the sweep cadence.
    # The guard is this node's liveness record: reaping one silent past the TTL
    # releases its room seats (freeing peer slots and occupied_keys, so an
    # abandoned room becomes evictable) and its connection slot, in one pass.
    def reap_leaked_connections
      ConnectionGuard.current.sweep
    rescue StandardError => e
      Rails.logger.error("room-sweeper (connection reap): #{e.class}: #{e.message}")
    end

    # The Rich text demo's Note records follow the same TTL. A note is touched
    # by every materialization (refresh_collaborative_rich_text saves it), so
    # updated_at tracks writes; a note whose document still exists is left to
    # the document sweep above (deleting the note would destroy a document the
    # occupancy check may be protecting). Once the document is gone — swept
    # above, or never created — a stale note is just an orphaned row.
    def sweep_notes(cutoff)
      stale = Note.where(updated_at: ...cutoff).where.missing(:collaborative_document_body)
      keys = stale.pluck(:room).map { |room| "note:#{room}" }
      stale.destroy_all
      keys
    end
  end
end
