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

      # Record every document change durably before it is applied or
      # distributed (authoritative audit mode). Called synchronously with
      # (key, update), where update is the exact CRDT delta, serialized per
      # document so the recorded order is the apply order. If the block raises,
      # the change is rejected: neither applied to the shared document nor
      # broadcast to other subscribers.
      #
      # Registering an on_change switches that channel onto the strict path
      # (record, apply, broadcast). Without it, the default fast path applies
      # and broadcasts, with an optional on_save snapshot.
      def on_change(callable = nil, &block)
        @on_change = callable || block if callable || block
        @on_change
      end

      # Select the document backend:
      #   :memory (default): keep a warm in-memory replica per process and keep
      #     it current via a custom stream_from callback. Fast, but it assumes
      #     classic ActionCable (the callback runs in Ruby) and
      #     process<->document affinity.
      #   :store: stateless per message, with no warm replica and no custom
      #     stream callback. Handshakes and reads are served from the durable
      #     store (`on_load`); changes are recorded (`on_change`) and relayed.
      #     Works under AnyCable (broadcasts handled outside Ruby, no worker
      #     affinity) and across processes. Requires `on_load` and `on_change`.
      def sync_backend(mode = nil)
        @sync_backend = mode if mode
        @sync_backend || :memory
      end
    end

    # Call from `subscribed`. Streams broadcasts for this document and
    # transmits the server's opening handshake (SyncStep1 + awareness).
    def sync_for(key)
      @sync_key = key.to_s
      @sync_origin = SecureRandom.hex(8)
      @sync_clients = [] # awareness client IDs seen on this connection

      return sync_for_store_backed if self.class.sync_backend == :store

      Sync.subscribe(@sync_key)
      awareness = sync_awareness

      stream_from sync_stream_name, coder: ActiveSupport::JSON do |payload|
        sync_on_broadcast(payload)
      end

      # Opening handshake: SyncStep1 then the current awareness, each as its
      # own single-message frame, so providers that parse one message per frame
      # (e.g. @y-rb/actioncable) handle both. The client replies SyncStep2 to
      # the SyncStep1, delivering its state to the server.
      sync_transmit(awareness.sync_step1)
      sync_transmit(awareness.encode_awareness_update)
    end

    # Call from `receive`. Applies the client's message, replies directly
    # when the protocol calls for it, and relays document/awareness changes
    # to the other subscribers.
    #
    # If an `on_change` recorder is registered, document changes take the
    # strict authoritative path (record -> apply -> broadcast, serialized per
    # document); otherwise the fast path is used.
    def sync_receive(data, key = nil)
      # Pass `key` (params[:id]) when your transport doesn't keep the channel
      # instance alive across actions. Under AnyCable each RPC command gets a
      # fresh channel, so instance variables set in `subscribed` are gone here.
      @sync_key = key.to_s if key

      # Accept both envelope keys: "m" (yrb-lite's own clients) and "update"
      # (the @y-rb/actioncable browser provider).
      m = data.is_a?(Hash) ? (data["m"] || data["update"]) : nil
      return unless m.is_a?(String)

      begin
        bytes = Base64.strict_decode64(m)
      rescue ArgumentError
        return # not valid base64; ignore the frame and keep the connection
      end

      return sync_receive_store_backed(m, bytes) if self.class.sync_backend == :store

      awareness = sync_awareness
      kind = awareness.message_kind(bytes)
      # Malformed / truncated / multi-message / unknown frames are dropped
      # before they can be processed or relayed to other clients.
      return if kind == MSG_KIND_DROP

      sync_track_clients(awareness, bytes) if kind == MSG_KIND_AWARENESS

      if kind == MSG_KIND_UPDATE && self.class.on_change
        sync_apply_authoritative(awareness, m, bytes)
      else
        sync_apply_fast(awareness, m, bytes, kind)
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
    # memory (only when an `on_load` is configured to bring it back; otherwise
    # the in-memory document is the only copy and is kept). Prevents a
    # long-running server from accumulating every document it has ever served.
    def sync_unsubscribed(key = nil)
      @sync_key = key.to_s if key
      return if self.class.sync_backend == :store # nothing cached per process

      sync_clear_presence
      saver = self.class.on_save
      Sync.release(@sync_key, evictable: !self.class.on_load.nil?) do |awareness|
        saver&.call(@sync_key, awareness.encode_state_as_update)
      end
    end

    # The shared Awareness (document + presence) for this channel's key.
    # Also useful for server-side reads, e.g.:
    #   sync_awareness.encode_state_as_update
    def sync_awareness
      Sync.awareness_for(@sync_key, self.class.on_load)
    end

    private

    # Default path: apply the message, answer direct requests, relay
    # state-changing messages to the other subscribers. Routing comes from the
    # native `kind` (from Awareness#message_kind) rather than peeking at bytes.
    # Document changes (SyncStep2, Update) and awareness get relayed; requests
    # (SyncStep1, awareness-query) are answered above and not relayed. An
    # optional on_save snapshot is taken after a document change.
    def sync_apply_fast(awareness, encoded, bytes, kind)
      response = awareness.handle(bytes)
      sync_transmit(response) unless response.empty?

      return unless [MSG_KIND_UPDATE, MSG_KIND_AWARENESS].include?(kind)

      sync_distribute(encoded)
      sync_persist if kind == MSG_KIND_UPDATE
    end

    # Authoritative path: record the change durably, then apply it to the
    # shared document, then distribute it. The sequence runs under a
    # per-document lock so changes are recorded in a single total order that
    # matches the order they're applied, and nothing is distributed (or applied)
    # before it has been recorded. If the recorder raises, the change is
    # rejected (not applied, not broadcast) and the exception propagates, so the
    # channel can surface it and the client can resync.
    def sync_apply_authoritative(awareness, encoded, bytes)
      recorder = self.class.on_change

      modified = Sync.lock_for(@sync_key).synchronize do
        update = awareness.update_from_message(bytes)
        # A no-op message (e.g. the empty SyncStep2 in a client's opening
        # handshake) carries no change, so there's nothing to record or relay.
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
    # `origin` identifies the sending connection (don't echo to it); `pid`
    # identifies the sending process (other processes apply it to their own
    # replica; see sync_on_broadcast).
    def sync_distribute(encoded)
      ActionCable.server.broadcast(
        sync_stream_name,
        sync_envelope(encoded, "origin" => @sync_origin, "pid" => Sync.process_id)
      )
    end

    # Transmit raw protocol bytes to this connection (base64, dual-key).
    def sync_transmit(bytes)
      transmit(sync_envelope(Base64.strict_encode64(bytes)))
    end

    # Build an outgoing envelope. We send the payload under both keys: "m"
    # (yrb-lite's own clients) and "update" (the @y-rb/actioncable provider),
    # so either client works against the same server.
    def sync_envelope(encoded, extra = {})
      { "m" => encoded, "update" => encoded }.merge(extra)
    end

    # Handle a broadcast delivered by the cable adapter. With a multi-process
    # adapter (Redis, solid_cable), it may have come from another server
    # process. Keep this process's in-memory replica current with changes that
    # originated elsewhere, then relay to this connection's browser.
    def sync_on_broadcast(payload)
      sync_apply_remote(payload["m"]) if payload["pid"] != Sync.process_id
      transmit(payload) unless payload["origin"] == @sync_origin
    end

    # Apply a change that originated on another process to this process's
    # replica, without re-recording it (the origin process already recorded it
    # before broadcasting). The CRDT merge is idempotent and commutative, so a
    # cold replica converges regardless of ordering, and applying from several
    # local connections is harmless.
    def sync_apply_remote(encoded)
      return unless encoded.is_a?(String)

      begin
        bytes = Base64.strict_decode64(encoded)
      rescue ArgumentError
        return
      end

      awareness = sync_awareness
      case awareness.message_kind(bytes)
      when MSG_KIND_UPDATE
        update = awareness.update_from_message(bytes)
        awareness.apply_update(update) if update
      when MSG_KIND_AWARENESS
        awareness.handle(bytes)
      end
    end

    # -- Store-backed (AnyCable-native) path --------------------------------

    # Subscribe without a custom block, so AnyCable (which delivers broadcasts
    # outside Ruby) relays them directly. Send the opening SyncStep1 built from
    # the durable store. No warm replica is kept.
    def sync_for_store_backed
      stream_from sync_stream_name
      sync_transmit(sync_load_doc.sync_step1)
    end

    # Stateless per message: no warm replica, no assumptions about which process
    # owns a document. A client's SyncStep1 is answered from the store, document
    # changes are recorded durably before relay and then broadcast, and
    # awareness is relayed best-effort. Echoing back to the sender is harmless,
    # since the CRDT apply is idempotent.
    def sync_receive_store_backed(encoded, bytes)
      case Sync.codec.message_kind(bytes)
      when MSG_KIND_SYNC_STEP1
        result = sync_load_doc.handle_sync_message(bytes)
        sync_transmit(result[2]) if result
      when MSG_KIND_UPDATE
        update = Sync.codec.update_from_message(bytes)
        return unless update

        self.class.on_change&.call(@sync_key, update) # record before relay
        sync_distribute(encoded)
      when MSG_KIND_AWARENESS
        sync_distribute(encoded)
      end
    end

    # Build a fresh document from the durable store (on_load).
    def sync_load_doc
      doc = YrbLite::Doc.new
      state = self.class.on_load&.call(@sync_key)
      doc.apply_update(state) if state
      doc
    end

    # Record the awareness client IDs carried by an incoming message (already
    # known to be an awareness frame) so we can clear them when this connection
    # closes.
    def sync_track_clients(awareness, bytes)
      awareness.awareness_client_ids(bytes).each do |id|
        @sync_clients << id unless @sync_clients.include?(id)
      end
    end

    def sync_stream_name
      "yrb_lite:#{@sync_key}"
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
      # A stable id for this server process, stamped on every broadcast so
      # other processes know to apply it to their replica and this process
      # knows to skip its own. Survives for the life of the process.
      def process_id
        @process_id ||= SecureRandom.hex(8)
      end

      # A shared, stateless decoder for the store-backed path. message_kind and
      # update_from_message only read their argument (they don't touch the
      # instance's document), so one shared instance is safe across threads.
      def codec
        @codec ||= YrbLite::Awareness.new
      end

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
      # data), persist it via the given block and unload it from memory, so a
      # long-running server doesn't accumulate every document and lock it has
      # ever seen. Returns true if the document was evicted.
      #
      # The persist runs outside the registry lock (it may do I/O), and we
      # re-check the subscriber count afterward: if someone reconnected while
      # we were saving, eviction is aborted and the warm document is kept.
      def release(key, evictable:)
        awareness = @registry_mutex.synchronize do
          @subscribers[key] -= 1 if @subscribers[key].positive?
          next nil unless @subscribers[key].zero?

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
