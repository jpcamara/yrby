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
      cutoff = Time.current - ttl
      stale = Y::Document.where(updated_at: ...cutoff)
                         .where.not(id: Y::DocumentUpdate.where(created_at: cutoff..).select(:document_id))
                         .where.not(key: rooms.occupied_keys)
      evicted = stale.pluck(:key)
      # destroy_all, not delete_all: Y::Document owns its update rows
      # (dependent: :delete_all), and destroying through the model keeps that
      # in one place.
      stale.destroy_all
      evicted.each { |key| rooms.forget(key) }
      Rails.logger.info("room-sweeper: evicted #{evicted.length} stale room(s)") if evicted.any?
      evicted
    rescue StandardError => e
      # A sweep failure must never take the thread down with it; the next tick
      # tries again.
      Rails.logger.error("room-sweeper: #{e.class}: #{e.message}")
      []
    end
  end
end
