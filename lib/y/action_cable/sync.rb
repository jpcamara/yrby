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
  # The concern is store-backed: Y::Sync::Engine rebuilds each document
  # through `on_load`, records a new update through `on_change` before it is
  # broadcast, and relays an already-stored retry without recording it again.
  # No authoritative document state is kept in ActionCable process memory.
  #
  # The protocol state machine lives in Y::Sync::Engine; this concern is the
  # ActionCable adapter over it: it decodes the cable envelope, calls the
  # engine, and routes the result back through `transmit` and
  # `ActionCable.server.broadcast`.
  module Sync
    # Default incoming-frame size cap (decoded bytes). Generous enough for a
    # large initial SyncStep2, small enough to bound a single message's
    # allocation/parse cost. Override per channel with `max_frame_bytes`.
    DEFAULT_MAX_FRAME_BYTES = 8 * 1024 * 1024

    # Canonically on the engine, with the state machine that reads them.
    # Kept in this namespace because they were reachable here.
    MSG_KIND_SYNC_STEP1 = Y::Sync::Engine::MSG_KIND_SYNC_STEP1
    MSG_KIND_UPDATE = Y::Sync::Engine::MSG_KIND_UPDATE
    MSG_KIND_AWARENESS = Y::Sync::Engine::MSG_KIND_AWARENESS

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Load persisted document state. Called with (key) every time the engine
      # rebuilds the document, which is once per handshake and once per
      # incoming update; return a binary Y.js update, or nil for a fresh
      # document. Runs in the channel instance's context (instance_exec).
      def on_load(&block)
        @on_load = block if block
        return @on_load if defined?(@on_load) && @on_load

        superclass.respond_to?(:on_load) ? superclass.on_load : nil
      end

      # Record a new document change durably, before it is broadcast or
      # acked. Called synchronously with (key, update), where update is the
      # exact CRDT delta. An update already present in the store is relayed
      # without calling this again. If the block raises, the change is
      # rejected: neither acknowledged nor broadcast. Concurrent deliveries
      # of the same delta can both reach it, so it must tolerate duplicates.
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

    # Call from `receive`. Hands the client's frame to the engine, replies
    # directly when the protocol calls for it, and relays document and
    # awareness frames to the document stream.
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
        sync_log_drop(:debug, "not valid base64", id)
        return
      end

      if cap && bytes.bytesize > cap
        sync_log_drop(:warn, "decoded #{bytes.bytesize}B exceeds max_frame_bytes #{cap}B", id)
        return
      end

      sync_send_ack(id, sync_handle_frame(encoded, bytes))
    end

    private

    # One engine per channel instance. Its hooks run on_load and on_change in
    # this instance's context (instance_exec), so they can reach current_user,
    # params, and the channel's own methods.
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

    # Override in the channel to add identifying context to dropped-frame and
    # gap-resync logs: a user id, a connection id, a request id. Return a short
    # string, or nil for none. Default: no extra context.
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
        # Report a broken context hook in the log line rather than raising.
        context = begin
          sync_log_context
        rescue StandardError => e
          "log-context-error=#{e.class}"
        end
        parts << context if context
        "[yrby] dropped frame (#{parts.join(" ")}): #{reason}"
      end
    end

    # Log every causal-gap resync with the document key and sync_log_context.
    # The reject path sends no error to the client, so this is the only
    # record of how often updates arrive ahead of their dependencies. A
    # client retrying the same gapped update logs each time; override to
    # change the level or silence it.
    def sync_log_gap_resync
      logger.info do
        parts = ["key=#{@sync_key.inspect}"]
        # Report a broken context hook in the log line rather than raising.
        context = begin
          sync_log_context
        rescue StandardError => e
          "log-context-error=#{e.class}"
        end
        parts << context if context
        "[yrby] causal-gap resync (update depends on a prior update the store hasn't seen): #{parts.join(" ")}"
      end
    end

    # Both hooks are required: the engine needs stored state to rebuild the
    # document and detect causal gaps, and a new update must be persisted
    # before it is broadcast or acked. Without them the channel would ack and
    # broadcast updates that were never stored, and a cold load or reconnect
    # would lose them.
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
    # Proceeding would record under nil, broadcast on a stream derived from
    # nil, and still ack, telling the client an edit landed on a document it
    # never reached.
    def sync_validate_key!
      return unless @sync_key.nil? || @sync_key.empty?

      raise Y::Error,
            "Y::ActionCable::Sync has no document key. Call sync_subscribed(key) in " \
            "subscribed, and pass the key to sync_receive(data, key) when the transport " \
            "doesn't keep the channel instance alive across actions (e.g. AnyCable)."
    end

    # Hand one decoded frame to the engine and route its Result onto the
    # cable: a direct reply to the sender (a SyncStep2 or a resync request),
    # or a broadcast on the document stream, or neither. Routing happens
    # before the ack outcome goes back to sync_send_ack, so an ack never
    # promises delivery that has not been attempted.
    def sync_handle_frame(encoded, bytes)
      sync_validate_required_hooks!
      sync_validate_key!

      result = sync_engine.handle(@sync_key, encoded, bytes)
      sync_transmit(result.reply) if result.reply
      sync_distribute(result.broadcast) if result.broadcast
      sync_log_gap_resync if result.ack == :gap
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
