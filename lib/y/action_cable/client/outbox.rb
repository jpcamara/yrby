# frozen_string_literal: true

module Y::ActionCable # rubocop:disable Style/ClassAndModuleChildren
  class Client
    # The local updates the server has not acknowledged yet, in the order
    # they were made. Each carries the id the server acks; an ack confirms
    # every update up to it. Nothing here touches the socket: the session
    # sends what `pending` holds and this drops what `ack` confirms. It is
    # the JS provider's ReliableSync without the merge, since yrby has no
    # update merge: a retransmit sends the pending updates one by one, in
    # order, which on one socket keeps them causally complete.
    class Outbox
      Pending = Data.define(:id, :update)

      def initialize
        @pending = []
        @next_id = 1
      end

      def pending = @pending.dup

      def pending? = !@pending.empty?

      # Queue a local update. Returns it with the id it will be acked by.
      def push(update)
        entry = Pending.new(id: @next_id, update: update)
        @next_id += 1
        @pending << entry
        entry
      end

      # Confirm delivery of every update up to `id`. The value comes off the
      # wire: one that is not an integer, or names an id never sent, drops
      # nothing. Returns true when something was confirmed.
      def ack(id) # rubocop:disable Naming/PredicateMethod -- an action that reports whether it did anything
        return false unless id.is_a?(Integer) && id.positive? && id < @next_id

        before = @pending.size
        @pending.reject! { |entry| entry.id <= id }
        @pending.size < before
      end
    end
  end
end
