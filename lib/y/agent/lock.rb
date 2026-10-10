# frozen_string_literal: true

require "securerandom"

module Y
  class Agent
    # The one-agent-per-document lock: a key in an ActiveSupport::Cache store
    # holding this agent's token. It is written only if absent, and a thread
    # of its own renews it every LOCK_TTL / 3 seconds while the agent stays,
    # however long a handler or a model call takes. It lapses LOCK_TTL
    # seconds after the last renewal, so an agent whose process died doesn't
    # hold the document for good.
    #
    # Cache stores have no atomic compare-and-set, so a renewal and a release
    # read the key and then write or delete it. That leaves one gap: a
    # process that stalls longer than LOCK_TTL loses the lock, and while it
    # comes back, it can briefly overlap the agent that took over. Its next
    # renewal sees the other token and it stops.
    class Lock
      def initialize(store, key)
        @store = store
        @key = key
        @token = SecureRandom.uuid
        @held = false
      end

      # Takes the lock if nobody holds it, and starts renewing it.
      def take
        @held = @store.write(@key, @token, unless_exist: true, expires_in: LOCK_TTL) ? true : false
        @renewer = Thread.new { renew_until_lost } if @held
        @held
      end

      # False once another agent holds the lock.
      def held? = @held

      def release
        @renewer&.kill
        @store.delete(@key) if @held && @store.read(@key) == @token
        @held = false
      end

      private

      def renew_until_lost
        while @held
          sleep LOCK_TTL / 3.0
          renew
        end
      end

      def renew
        holder = @store.read(@key)
        return @held = false if holder && holder != @token

        @store.write(@key, @token, expires_in: LOCK_TTL)
      end
    end
  end
end
