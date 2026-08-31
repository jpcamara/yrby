# Drops idle rooms from memory.
#
# Without this the store only ever grows: every visitor mints a room, most are
# abandoned within a minute, and MAX_LIVE_ROOMS would be reached by ordinary
# traffic rather than by abuse. A room with nobody in it and no writes for
# ROOM_IDLE_TTL is deleted.
#
# One plain Ruby thread, started once at boot. It does nothing but sleep, so it
# is cheap under Falcon's fiber scheduler as well as Puma's threads.
module RoomSweeper
  class << self
    def start(store: RoomStore.current, interval: Limits::SWEEP_INTERVAL)
      return @thread if @thread&.alive?

      @thread = Thread.new do
        Thread.current.name = "room-sweeper"
        loop do
          sleep interval
          run_once(store)
        end
      end
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    def run_once(store = RoomStore.current)
      evicted = store.sweep
      Rails.logger.info("room-sweeper: evicted #{evicted.length} idle room(s)") if evicted.any?
      evicted
    rescue StandardError => e
      # A sweep failure must never take the thread down with it; the next tick
      # tries again.
      Rails.logger.error("room-sweeper: #{e.class}: #{e.message}")
      []
    end
  end
end
