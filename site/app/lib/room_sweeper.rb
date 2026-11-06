# Deletes stale documents and rooms from the store.
#
# An idle room costs a few rows on disk and no RAM, so this isn't about
# memory. It's about content. These documents are public, anonymous, and
# unmoderated, and the site tells visitors they're temporary. ROOM_IDLE_TTL
# sets how long that is. A document that nobody touches for ROOM_IDLE_TTL is
# deleted along with its rows, and so is a room with nothing left in it.
#
# A document counts as untouched when it has no write and no compaction inside
# the TTL. Appends set y_document_updates.created_at and compaction sets
# y_documents.updated_at, so a document is stale only when both are old. A
# document with someone seated in it is never deleted, however quiet it is.
#
# This runs as one plain Ruby thread in each server process, started once at
# boot. It sleeps between sweeps. Under Falcon it runs next to the fiber
# reactor, and a sleeping thread costs nothing. Every process sweeps the same
# rows, and each step is one transaction, so two sweeps at once delete each
# row once.
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

    # Returns the keys of the documents it deleted and "room:<slug>" for each
    # room.
    def run_once(rooms: Rooms.current, ttl: Limits::ROOM_IDLE_TTL)
      cutoff = Time.current - ttl
      reap_leaked_seats
      evicted = sweep_documents(rooms, cutoff) + sweep_rooms(cutoff)
      Rails.logger.info("room-sweeper: evicted #{evicted.length} stale document(s) and room(s)") if evicted.any?
      reap_leaked_connections
      evicted
    rescue StandardError => e
      # Keep the thread alive after a failed sweep. The next tick tries again.
      Rails.logger.error("room-sweeper: #{e.class}: #{e.message}")
      # The connection cleanup is the only thing that frees leaked slots, so a
      # failed room sweep shouldn't skip it. It has its own rescue.
      reap_leaked_connections
      []
    end

    # Deletes stale documents nobody is seated in. The check and the delete
    # are one transaction, and a join is one transaction too, so a join either
    # lands first and keeps the document, or waits and seats its client in a
    # document that starts over. A document from before rooms had rows, keyed
    # by "demo/room" with no record, has no seats and goes after the TTL.
    def sweep_documents(rooms, cutoff)
      keys = Y::Document.transaction do
        stale = stale_documents(cutoff).where.not(id: seated_documents.select(:id))
        stale.pluck(:key).tap { stale.destroy_all }
      end
      keys.each { |key| rooms.forget(key) }
      keys
    end

    # Deletes rooms with no documents left and nobody seated, once the room
    # row itself is stale too. Every Lexxy render saves the room
    # (collaborative_document(:body).refresh), so updated_at tracks those
    # writes, and a room someone just started is kept for the TTL even before
    # its first write.
    def sweep_rooms(cutoff)
      Room.transaction do
        stale = Room.where(updated_at: ...cutoff).where.missing(:documents, :seats)
        stale.pluck(:slug).map { |slug| "room:#{slug}" }.tap { stale.delete_all }
      end
    end

    # Documents with no compaction (updated_at) and no append (a new update
    # row) inside the TTL.
    def stale_documents(cutoff)
      Y::Document.where(updated_at: ...cutoff)
                 .where.not(id: Y::DocumentUpdate.where(created_at: cutoff..).select(:document_id))
    end

    def seated_documents
      Y::Document.joins("INNER JOIN seats ON seats.room_type = y_documents.record_type " \
                        "AND seats.room_id = y_documents.record_id AND seats.name = y_documents.name")
    end

    def reap_leaked_seats
      Seat.stale.delete_all
    end

    # Cleans up connections whose Disconnect RPC never arrived, on each sweep.
    # ConnectionGuard tracks which connections this process has heard from.
    # When it removes one that's been silent past the TTL, it frees its
    # connection slot.
    def reap_leaked_connections
      ConnectionGuard.current.sweep
    rescue StandardError => e
      Rails.logger.error("room-sweeper (connection cleanup): #{e.class}: #{e.message}")
    end
  end
end
