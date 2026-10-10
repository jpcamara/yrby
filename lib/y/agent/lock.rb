# frozen_string_literal: true

require "securerandom"

module Y
  class Agent
    # The one-agent-per-document lock: a key in an ActiveSupport::Cache store
    # holding this agent's token, written only if absent and renewed while
    # the agent stays. It lapses LOCK_TTL seconds after the last renewal, so
    # an agent whose process died doesn't hold the document forever.
    class Lock
      def initialize(store, key)
        @store = store
        @key = key
        @token = SecureRandom.uuid
      end

      def take
        @renewed = now
        @store.write(@key, @token, unless_exist: true, expires_in: LOCK_TTL)
      end

      # Renews a few times per LOCK_TTL. Returns false when another agent
      # holds the lock, which means this one outlived a lapse and leaves.
      def keep
        return true unless now - @renewed > LOCK_TTL / 3

        holder = @store.read(@key)
        return false if holder && holder != @token

        @renewed = now
        @store.write(@key, @token, expires_in: LOCK_TTL)
      end

      def release
        @store.delete(@key) if @store.read(@key) == @token
      end

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
