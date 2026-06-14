# frozen_string_literal: true

require "base64"
require "securerandom"

module YrbLite
  # y-websocket protocol over ActionCable.
  #
  # Include this module in an ActionCable channel to sync Y.js documents
  # (and awareness/presence) with browser clients. Messages are the standard
  # y-protocols binary messages, base64-encoded in a JSON envelope:
  #
  #   { "m" => "<base64 bytes>" }              # client -> server
  #   { "m" => "...", "origin" => "<id>" }     # server -> subscribers
  #
  # Example:
  #   class DocumentChannel < ApplicationCable::Channel
  #     include YrbLite::Sync
  #
  #     on_load { |key| Document.find_by(key: key)&.content }
  #     on_save { |key, update| Document.find_by(key: key)&.update!(content: update) }
  #
  #     def subscribed
  #       sync_for params[:id]
  #     end
  #
  #     def receive(data)
  #       sync_receive(data)
  #     end
  #
  #     def unsubscribed
  #       sync_clear_presence
  #     end
  #   end
  #
  # The shared YrbLite::Awareness instances are safe to use from ActionCable's
  # worker thread pool: the native types are Send + Sync and every operation
  # releases the GVL, so concurrent clients sync in parallel.
  module Sync
    MSG_SYNC = 0
    MSG_AWARENESS = 1
    MSG_SYNC_STEP1 = 0

    # Validated frame kinds from Awareness#message_kind. A frame only gets a
    # non-DROP kind if it is exactly one well-formed message; anything
    # malformed, truncated, multi-message, or unknown is dropped before it can
    # be processed or relayed.
    MSG_KIND_DROP = 0
    MSG_KIND_SYNC_STEP1 = 1
    MSG_KIND_UPDATE = 2
    MSG_KIND_AWARENESS = 3
    MSG_KIND_AWARENESS_QUERY = 4

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Load persisted document state. Called once per key with (key);
      # return a binary Y.js update (or nil for a fresh document).
      def on_load(callable = nil, &block)
        @on_load = callable || block if callable || block
        @on_load
      end

      # Persist document state. Called with (key, update) after every
      # message that modified the document.
      def on_save(callable = nil, &block)
        @on_save = callable || block if callable || block
        @on_save
      end

      # Record every document change durably *before* it is applied or
      # distributed (authoritative audit mode). Called with (key, update) —
      # the exact CRDT update delta — synchronously, serialized per document
      # so the recorded order is the authoritative apply order. If the block
      # raises, the change is rejected: it is neither applied to the shared
      # document nor broadcast to other subscribers.
      #
      # Registering an on_change switches that channel onto the strict path
      # (record -> apply -> broadcast). Without it, the default fast path
      # (apply -> broadcast, optional on_save snapshot) is used.
      def on_change(callable = nil, &block)
        @on_change = callable || block if callable || block
        @on_change
      end
    end

    # Call from `subscribed`. Streams broadcasts for this document and
    # transmits the server's opening handshake (SyncStep1 + awareness).
    def sync_for(key)
      @sync_key = key.to_s
      @sync_origin = SecureRandom.hex(8)
      @sync_clients = [] # awareness client IDs seen on this connection
      Sync.subscribe(@sync_key)
      awareness = sync_awareness

      stream_from sync_stream_name, coder: ActiveSupport::JSON do |payload|
        # Don't echo a client's own messages back to it.
        transmit(payload) unless payload["origin"] == @sync_origin
      end

      transmit({ "m" => Base64.strict_encode64(awareness.start) })
    end

    # Call from `receive`. Applies the client's message, replies directly
    # when the protocol calls for it, and relays document/awareness changes
    # to the other subscribers.
    #
    # If an `on_change` recorder is registered, document changes take the
    # strict authoritative path (record -> apply -> broadcast, serialized per
    # document); otherwise the fast path is used.
    def sync_receive(data)
      m = data.is_a?(Hash) ? data["m"] : nil
      return unless m.is_a?(String)

      begin
        bytes = Base64.strict_decode64(m)
      rescue ArgumentError
        return # not valid base64 — ignore the frame, keep the connection
      end

      awareness = sync_awareness
      kind = awareness.message_kind(bytes)
      # Malformed / truncated / multi-message / unknown frames are dropped
      # before they can be processed or relayed to other clients.
      return if kind == MSG_KIND_DROP

      sync_track_clients(awareness, bytes) if kind == MSG_KIND_AWARENESS

      if kind == MSG_KIND_UPDATE && self.class.on_change
        sync_apply_authoritative(awareness, m, bytes)
      else
        sync_apply_fast(awareness, m, bytes)
      end
    end

    # Call from `unsubscribed`. Clears the presence states this connection
    # introduced and tells the other subscribers to drop those cursors, so a
    # closed tab or dropped socket doesn't leave a ghost cursor behind until
    # the client-side timeout reaps it.
    def sync_clear_presence
      return if @sync_clients.nil? || @sync_clients.empty?

      removal = sync_awareness.remove_clients(@sync_clients)
      @sync_clients = []
      return if removal.empty?

      sync_distribute(Base64.strict_encode64(removal))
    end

    # Call from `unsubscribed`. Clears this connection's presence and, when the
    # last subscriber for the document leaves, persists and unloads it from
    # memory (only if an `on_load` is configured to bring it back — otherwise
    # the in-memory document is the only copy and is kept). Prevents a
    # long-running server from accumulating every document it has ever served.
    def sync_unsubscribed
      sync_clear_presence
      saver = self.class.on_save
      Sync.release(@sync_key, evictable: !self.class.on_load.nil?) do |awareness|
        saver&.call(@sync_key, awareness.encode_state_as_update)
      end
    end

    # The shared Awareness (document + presence) for this channel's key.
    # Also useful for server-side reads, e.g.:
    #   YrbLite::ProseMirrorExtractor.extract(sync_awareness.encode_state_as_update)
    def sync_awareness
      Sync.awareness_for(@sync_key, self.class.on_load)
    end

    private

    # Default path: apply the message, answer direct requests, relay
    # state-changing messages to the other subscribers. An optional on_save
    # snapshot is taken after a document change.
    def sync_apply_fast(awareness, encoded, bytes)
      response = awareness.handle(bytes)
      transmit({ "m" => Base64.strict_encode64(response) }) unless response.empty?

      return unless sync_broadcast?(bytes)

      sync_distribute(encoded)
      sync_persist if sync_modifies_doc?(bytes)
    end

    # Authoritative path: record the change durably, THEN apply it to the
    # shared document, THEN distribute it. The whole sequence runs under a
    # per-document lock so changes are recorded in a single total order that
    # matches the order they are applied, and nothing is ever distributed (or
    # even applied) before it has been recorded. If the recorder raises, the
    # change is rejected — not applied, not broadcast — and the exception
    # propagates so the channel can surface it / the client can resync.
    def sync_apply_authoritative(awareness, encoded, bytes)
      recorder = self.class.on_change

      modified = Sync.lock_for(@sync_key).synchronize do
        update = awareness.update_from_message(bytes)
        # A no-op message (e.g. the empty SyncStep2 in a client's opening
        # handshake) carries no change — nothing to record, apply, or relay.
        next false unless update

        recorder.call(@sync_key, update) # durable write; raise to reject
        awareness.apply_update(update)   # only recorded changes reach the doc
        sync_distribute(encoded)         # ...and only then the wire
        true
      end

      sync_persist if modified
    end

    # Single broadcast point for both paths (and presence removal), so the
    # relay semantics live in one place and tests can observe distribution.
    def sync_distribute(encoded)
      ActionCable.server.broadcast(
        sync_stream_name,
        { "m" => encoded, "origin" => @sync_origin }
      )
    end

    # Record the awareness client IDs carried by an incoming message so we
    # can clear exactly those states when this connection closes.
    def sync_track_clients(awareness, bytes)
      return unless bytes.getbyte(0) == MSG_AWARENESS

      awareness.awareness_client_ids(bytes).each do |id|
        @sync_clients << id unless @sync_clients.include?(id)
      end
    end

    def sync_stream_name
      "yrb_lite:#{@sync_key}"
    end

    # Relay messages that change shared state: SyncStep2/Update (document
    # content) and awareness updates. SyncStep1 is a request addressed to
    # the server alone — relaying it would make every client answer.
    def sync_broadcast?(bytes)
      case bytes.getbyte(0)
      when MSG_SYNC then bytes.getbyte(1) != MSG_SYNC_STEP1
      when MSG_AWARENESS then true
      else false
      end
    end

    def sync_modifies_doc?(bytes)
      bytes.getbyte(0) == MSG_SYNC && bytes.getbyte(1) != MSG_SYNC_STEP1
    end

    def sync_persist
      return unless (saver = self.class.on_save)

      saver.call(@sync_key, sync_awareness.encode_state_as_update)
    end

    # -- Shared document registry ------------------------------------------

    @registry = {}
    @locks = {}
    @subscribers = Hash.new(0)
    @registry_mutex = Mutex.new

    class << self
      # Get or create the shared Awareness for a key. Creation (including
      # the on_load callback) is serialized under a mutex so concurrent
      # subscribers can never observe two documents for one key; all
      # subsequent operations run lock-free on the thread-safe native types.
      def awareness_for(key, loader = nil)
        @registry_mutex.synchronize do
          @registry[key] ||= begin
            awareness = YrbLite::Awareness.new
            if loader && (state = loader.call(key))
              awareness.apply_update(state)
            end
            awareness
          end
        end
      end

      # Per-document mutex serializing the authoritative record -> apply ->
      # broadcast section, so a document's audit log is a single total order.
      # Only briefly holds the registry mutex to fetch/create the lock; the
      # durable write itself runs while holding only this per-key lock.
      def lock_for(key)
        @registry_mutex.synchronize { @locks[key] ||= Mutex.new }
      end

      # Count a new subscriber for a document.
      def subscribe(key)
        @registry_mutex.synchronize { @subscribers[key] += 1 }
      end

      # Drop a subscriber. When the last one leaves and the document is
      # evictable (there's an on_load to bring it back, so unloading can't lose
      # data), persist it via the given block and unload it from memory — so a
      # long-running server doesn't accumulate every document and lock it has
      # ever seen. Returns true if the document was evicted.
      #
      # The persist runs outside the registry lock (it may do I/O), and we
      # re-check the subscriber count afterward: if someone reconnected while
      # we were saving, eviction is aborted and the warm document is kept.
      def release(key, evictable:)
        awareness = @registry_mutex.synchronize do
          @subscribers[key] -= 1 if @subscribers[key].positive?
          next nil unless (@subscribers[key]).zero?

          @subscribers.delete(key)
          evictable ? @registry[key] : nil
        end
        return false unless awareness

        yield awareness if block_given?

        @registry_mutex.synchronize do
          # A subscriber may have returned during the persist above.
          next false unless @subscribers[key].zero?

          @subscribers.delete(key)
          @locks.delete(key)
          !@registry.delete(key).nil?
        end
      end

      def registry
        @registry_mutex.synchronize { @registry.dup }
      end

      # Clear all documents (useful for testing).
      def reset!
        @registry_mutex.synchronize do
          @registry = {}
          @locks = {}
          @subscribers = Hash.new(0)
        end
      end
    end
  end
end
