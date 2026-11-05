# frozen_string_literal: true

require "async"
require "securerandom"

module Y
  class Collaborator
    # The collaborator lock: a key in an ActiveSupport::Cache store holding
    # this collaborator's token. It is written only if absent, and a task on
    # the collaborator's reactor renews it every LOCK_TTL / 3 seconds while
    # the collaborator stays, so a handler waiting on a model call doesn't
    # let it lapse. It lapses LOCK_TTL seconds after the last renewal, so a
    # collaborator whose process died doesn't hold the document for good.
    #
    # Cache stores have no atomic compare-and-set, so a renewal and a release
    # read the key and then write or delete it. That leaves one gap: a process
    # that stalls longer than LOCK_TTL loses the lock, and while it comes
    # back, it can briefly overlap the collaborator that took over. Its next
    # renewal sees the other token and it stops.
    class Lock
      # One key per document, or per document and `as` when it's given. A
      # record is named by its GlobalID, so a Person and a Team with the same
      # id don't share a key.
      def self.key(document, as)
        return "yrby:collaborator:#{document.key}" if as.nil?

        "yrby:collaborator:#{document.key}:#{as.respond_to?(:to_global_id) ? as.to_global_id : as}"
      end

      def initialize(store, key)
        @store = store
        @key = key
        @token = SecureRandom.uuid
        @held = false
      end

      # Takes the lock if nobody holds it, and starts renewing it in a task
      # of the current reactor. `release` stops the task.
      def take
        @held = @store.write(@key, @token, unless_exist: true, expires_in: LOCK_TTL) ? true : false
        @renewer = Async::Task.current.async { renew_until_lost } if @held
        @held
      end

      # False once another collaborator holds the lock.
      def held? = @held

      def release
        @renewer&.stop
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
