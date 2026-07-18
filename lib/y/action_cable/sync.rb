# frozen_string_literal: true

require "y"
require "base64"

module Y::ActionCable # rubocop:disable Style/ClassAndModuleChildren
  # y-websocket protocol over ActionCable.
  #
  # Include this module in an ActionCable channel to sync Y.js documents
  # (and awareness/presence) with browser clients. Messages are the standard
  # y-protocols binary messages, base64-encoded in a JSON envelope:
  #
  #   { "update" => "<base64 bytes>", "id" => 42 } # client -> server
  #   { "update" => "<base64 bytes>" }             # server -> subscribers
  #   { "ack" => 42 }                              # server -> sender
  #
  # Example:
  #   class DocumentChannel < ApplicationCable::Channel
  #     include Y::ActionCable::Sync
  #
  #     on_load { |key| Document.find_by(key: key)&.content }
  #     # on_change runs in the channel instance's context, so instance methods
  #     # (current_user, params, ...) are available:
  #     on_change { |key, update| Document.record!(key, update, by: current_user) }
  #
  #     def subscribed
  #       sync_subscribed params[:id]
  #     end
  #
  #     def receive(data)
  #       sync_receive(data)
  #     end
  #   end
  #
  # There is no unsubscribe hook: the server keeps no per-connection document or
  # presence state, so a disconnect needs no server-side cleanup.
  #
  # The concern is store-backed and fail-closed: every document update is
  # validated against `on_load`, recorded through `on_change`, then broadcast.
  # No authoritative document state is kept in ActionCable process memory.
  #
  # The protocol state machine lives in Y::Sync::Engine; this concern is the
  # ActionCable adapter over it — it decodes the cable envelope, calls the
  # engine, and routes the result back through `transmit` and
  # `ActionCable.server.broadcast`.
  module Sync
    # Default incoming-frame size cap (decoded bytes). Generous enough for a
    # large initial SyncStep2, small enough to bound a single message's
    # allocation/parse cost. Override per channel with `max_frame_bytes`.
    DEFAULT_MAX_FRAME_BYTES = 8 * 1024 * 1024

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Load persisted document state. Called once per key with (key); return a
      # binary Y.js update (or nil for a fresh document). Runs in the channel
      # instance's context (instance_exec).
      def on_load(&block)
        @on_load = block if block
        return @on_load if defined?(@on_load) && @on_load

        superclass.respond_to?(:on_load) ? superclass.on_load : nil
      end

      # Record every document change durably before it is applied or
      # distributed. Called synchronously with (key, update), where update is
      # the exact CRDT delta. If the block raises, the change is rejected:
      # neither acknowledged nor broadcast to other subscribers.
      #
      # Runs in the channel instance's context (instance_exec). Fires from within
      # sync_receive.
      def on_change(&block)
        @on_change = block if block
        return @on_change if defined?(@on_change) && @on_change

        superclass.respond_to?(:on_change) ? superclass.on_change : nil
      end

      # Maximum size, in decoded bytes, of an incoming document/awareness frame.
      # Oversized frames are dropped before base64 decode and before native
      # parsing, so a client can't force huge allocations/CPU (a DoS vector).
      # Defaults to DEFAULT_MAX_FRAME_BYTES; set to nil to disable the cap.
      def max_frame_bytes(bytes = :__unset__)
        # Combined reader/writer; the sentinel keeps nil a real value (disables the cap).
        @max_frame_bytes = bytes unless bytes == :__unset__
        return @max_frame_bytes if defined?(@max_frame_bytes)

        superclass.respond_to?(:max_frame_bytes) ? superclass.max_frame_bytes : DEFAULT_MAX_FRAME_BYTES
      end
    end

    # Call from `subscribed`. Streams broadcasts for this document and
    # transmits the server's opening handshake (SyncStep1 from the store).
    def sync_subscribed(key)
      @sync_key = key.to_s
      sync_validate_required_hooks!

      # The document stream is never whisper-enabled; under AnyCable we also
      # subscribe an awareness stream with `whisper: true`, scoping the client-to-
      # client path to ephemeral presence rather than the durable document stream.
      stream_from sync_stream_name
      stream_from sync_awareness_stream_name, whisper: true if respond_to?(:whispers_to)
      sync_transmit(sync_engine.sync_step1(@sync_key))
    end

    # Call from `receive`. Applies the client's message, replies directly
    # when the protocol calls for it, and relays document/awareness changes
    # to the other subscribers.
    #
    # Reliable delivery: document updates carry an "id", and the server replies
    # `{ "ack" => id }` once the update has been durably recorded. A
    # causally-gapped update is not acked; it gets a resync instead, so the
    # client retransmits until the update lands.
    def sync_receive(data, key = nil)
      # Pass `key` (params[:id]) when your transport doesn't keep the channel
      # instance alive across actions. Under AnyCable each RPC command gets a
      # fresh channel, so instance variables set in `subscribed` are gone here.
      @sync_key = key.to_s if key

      encoded = data.is_a?(Hash) ? data["update"] : nil
      return unless encoded.is_a?(String)

      # Optional client-supplied id for reliable delivery (see sync_send_ack).
      # data is known to be a Hash here (encoded came from it above).
      id = data["id"]

      # Frame-size cap: drop oversized frames before decoding (the encoded form
      # is ~4/3 the decoded size) and again after, so a client can't force large
      # base64 decodes / native parses / merges. A dropped frame is never acked,
      # and there is no protocol NACK, so a legitimate oversized update is
      # retransmitted indefinitely. Log the drop so it is at least findable.
      cap = self.class.max_frame_bytes
      if cap && encoded.bytesize > (cap * 4 / 3) + 4
        sync_log_drop(:warn, "encoded #{encoded.bytesize}B exceeds max_frame_bytes #{cap}B", id)
        return
      end

      begin
        bytes = Base64.strict_decode64(encoded)
      rescue ArgumentError
        sync_log_drop(:debug, "not valid base64", id) # garbage or a probe, rarely a real client
        return # ignore the frame and keep the connection
      end

      if cap && bytes.bytesize > cap
        sync_log_drop(:warn, "decoded #{bytes.bytesize}B exceeds max_frame_bytes #{cap}B", id)
        return
      end

      sync_send_ack(id, sync_handle_frame(encoded, bytes))
    end

    private

    # The transport-neutral protocol core. Built with hooks that run on_load /
    # on_change in THIS channel instance's context (instance_exec), so on_change
    # can reach current_user, params, and the channel's own methods — the same
    # binding the old inline recorder had. Memoized per instance; the engine is
    # stateless, so a fresh one per AnyCable-rebuilt channel costs nothing.
    def sync_engine
      @sync_engine ||= Y::Sync::Engine.new(
        load: ->(key) { instance_exec(key, &self.class.on_load) },
        change: ->(key, update) { instance_exec(key, update, &self.class.on_change) }
      )
    end

    # Reliable delivery: acknowledge an accepted update back to the sending
    # connection. An ack-aware client tags each outgoing update with an "id"
    # and retains it until the matching `{ "ack" => id }` returns, retransmitting
    # on a timer or reconnect; idempotent CRDT apply makes resends free. Acks
    # are sent only after the update has been durably recorded, or when a retry
    # is already present in the durable store.
    def sync_send_ack(id, outcome)
      return if id.nil?
      return unless %i[recorded applied].include?(outcome)

      # The braces are required: a bare hash would bind to transmit's `via:`
      # keyword instead of its positional data argument.
      transmit({ "ack" => id })
    end

    # Single broadcast point so relay semantics live in one place and tests can
    # observe distribution. Store-backed streams intentionally echo to the
    # sender; applying the same CRDT update twice is a no-op.
    def sync_distribute(encoded)
      ActionCable.server.broadcast(sync_stream_name, sync_envelope(encoded))
    end

    # Transmit raw protocol bytes to this connection.
    def sync_transmit(bytes)
      transmit(sync_envelope(Base64.strict_encode64(bytes)))
    end

    def sync_envelope(encoded)
      { "update" => encoded }
    end

    # Override in the channel to add identifying context to dropped-frame logs --
    # a user id, a connection id, a request id. Return a short string (or nil for
    # none); it is appended to the log line. Default: no extra context.
    def sync_log_context
      nil
    end

    # Surface a dropped frame through the channel logger. Drops are otherwise
    # invisible (no ack, no broadcast); an oversized legitimate update is never
    # acked and the client retransmits it forever, so make it findable. Names the
    # document key, the reliable-delivery id when present, and whatever
    # sync_log_context returns, so a drop can be tied to a specific document,
    # update, and connection.
    def sync_log_drop(level, reason, id = nil)
      logger.public_send(level) do
        parts = ["key=#{@sync_key.inspect}"]
        parts << "id=#{id}" unless id.nil?
        # A broken context hook must surface, not take down frame handling.
        context = begin
          sync_log_context
        rescue StandardError => e
          "log-context-error=#{e.class}"
        end
        parts << context if context
        "[yrby] dropped frame (#{parts.join(" ")}): #{reason}"
      end
    end

    # This concern acks updates as durably recorded, so it must have both a
    # loader (to rebuild the doc and detect causal gaps) and a recorder (to
    # actually persist before acking). Fail closed rather than silently acking
    # and broadcasting updates that were never stored, which a cold load or
    # reconnect would then lose.
    def sync_validate_required_hooks!
      missing = []
      missing << :on_load unless self.class.on_load
      missing << :on_change unless self.class.on_change
      return if missing.empty?

      raise Y::Error,
            "Y::ActionCable::Sync requires #{missing.join(" and ")}. Updates are acked as " \
            "durably recorded; without a loader and recorder, an ack would claim a persistence " \
            "that never happened, and a cold load would lose the edit."
    end

    # Fail closed when no document key is set (typically: AnyCable rebuilt the
    # channel instance and the app forgot to pass `key` to sync_receive).
    # Proceeding would record under nil, broadcast to a stream nobody
    # subscribes to, and still ack — the client believes the edit was
    # delivered when it reached no one.
    def sync_validate_key!
      return unless @sync_key.nil? || @sync_key.empty?

      raise Y::Error,
            "Y::ActionCable::Sync has no document key. Call sync_subscribed(key) in " \
            "subscribed, and pass the key to sync_receive(data, key) when the transport " \
            "doesn't keep the channel instance alive across actions (e.g. AnyCable)."
    end

    # Hand one decoded frame to the engine and route its Result onto the cable:
    # a direct reply to the sender (a SyncStep2 or a resync request), a
    # broadcast to the other subscribers, or both/neither. Returns the engine's
    # ack outcome for sync_send_ack.
    def sync_handle_frame(encoded, bytes)
      sync_validate_required_hooks!
      sync_validate_key!

      result = sync_engine.handle(@sync_key, encoded, bytes)
      sync_transmit(result.reply) if result.reply
      sync_distribute(result.broadcast) if result.broadcast
      result.ack
    end

    def sync_stream_name
      "yrby:#{@sync_key}"
    end

    def sync_awareness_stream_name
      "#{sync_stream_name}:awareness"
    end
  end
end
