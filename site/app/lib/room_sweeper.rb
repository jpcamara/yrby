# Deletes stale documents from the store.
#
# An idle room costs a few rows on disk and no RAM, so this isn't about
# memory. It's about content. These documents are public, anonymous, and
# unmoderated, and the site tells visitors they're temporary. ROOM_IDLE_TTL
# sets how long that is. A room that nobody touches for ROOM_IDLE_TTL is
# deleted along with its rows.
#
# A room counts as untouched when it has no write and no compaction inside the
# TTL. Appends set y_document_updates.created_at and compaction sets
# y_documents.updated_at, so a document is stale only when both are old. A room
# with someone in it is never deleted, however quiet it is.
#
# This runs as one plain Ruby thread in the server process, started once at
# boot. It sleeps between sweeps. Under Falcon it runs next to the fiber
# reactor, and a sleeping thread costs nothing.
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
      # Keep the thread alive after a failed sweep. The next tick tries again.
      Rails.logger.error("room-sweeper: #{e.class}: #{e.message}")
      # The connection cleanup is the only thing that frees leaked slots and seats,
      # so a failed room sweep shouldn't skip it. It has its own rescue.
      reap_leaked_connections
      []
    end

    # Deletes stale documents without racing a join or a write.
    #
    # `occupied_keys` is a snapshot. A join or an append could commit between
    # finding the stale set and deleting it, which would delete a document out
    # from under a live session, along with update rows written in that window.
    # So the stale set is only a list of candidates. Rooms#claim_evictions
    # checks seats and claims, in one locked step, the candidates with no
    # occupant and no reservation. After that, a join gets :evicting and a
    # write can't reopen them.
    #
    # Then this reads the database again for the claimed keys, because a write
    # between the candidate query and the claim leaves a new update row. It
    # deletes only the keys that are still stale and clears the mark on every
    # claimed key.
    def sweep_documents(rooms, ttl)
      cutoff = Time.current - ttl
      candidates = stale_document_keys(cutoff, exclude: rooms.occupied_keys)
      claimed = rooms.claim_evictions(candidates)
      return [] if claimed.empty?

      begin
        # Nothing can join or write to these keys while they're claimed, so this
        # second read is stable. It only catches writes from before the claim.
        evictable = stale_document_keys(cutoff, only: claimed)
        # Use destroy_all so Y::Document's `dependent: :delete_all` removes the
        # update rows, and that rule stays in the model.
        Y::Document.where(key: evictable).destroy_all if evictable.any?
        evictable
      ensure
        # Clear the evicting mark on every claimed key, deleted or not, so a
        # room the second read kept can be joined again.
        claimed.each { |key| rooms.forget(key) }
      end
    end

    # Keys whose document is stale: no compaction (updated_at) and no append
    # (a new update row) inside the TTL. `exclude` leaves out occupied rooms on
    # the first pass. `only` limits the second read to the claimed keys.
    def stale_document_keys(cutoff, exclude: nil, only: nil)
      scope = Y::Document.where(updated_at: ...cutoff)
                         .where.not(id: Y::DocumentUpdate.where(created_at: cutoff..).select(:document_id))
      scope = scope.where(key: only) if only
      scope = scope.where.not(key: exclude) if exclude&.any?
      scope.pluck(:key)
    end

    # Cleans up connections whose Disconnect RPC never arrived, on each sweep.
    # ConnectionGuard tracks which connections on this server are alive. When
    # it removes one that's been silent past the TTL, it frees its room seats
    # and its connection slot. Freeing the seats also lets an abandoned room be
    # deleted.
    def reap_leaked_connections
      ConnectionGuard.current.sweep
    rescue StandardError => e
      Rails.logger.error("room-sweeper (connection cleanup): #{e.class}: #{e.message}")
    end

    # The Lexxy demo's Note records use the same TTL. Every render saves the
    # note (refresh_collaborative_rich_text), so updated_at tracks writes. If
    # a note's document still exists, the document sweep above handles it,
    # because deleting the note would delete a document someone may be using.
    # Once the document is gone, or if it was never created, a stale note is
    # just an orphaned row.
    def sweep_notes(cutoff)
      stale = Note.where(updated_at: ...cutoff).where.missing(:collaborative_document_body)
      keys = stale.pluck(:room).map { |room| "note:#{room}" }
      stale.destroy_all
      keys
    end
  end
end
