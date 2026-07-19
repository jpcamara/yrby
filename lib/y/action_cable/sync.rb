# frozen_string_literal: true

require "y"
require "base64"
require "digest"

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
  module Sync
    # Frame kinds we act on, from Y.message_kind. Its other codes (0 for a
    # drop: malformed/truncated/multi-message/unknown, and 4 for an awareness
    # query) fall through to a no-op in the dispatch below.
    MSG_KIND_SYNC_STEP1 = 1
    MSG_KIND_UPDATE = 2
    MSG_KIND_AWARENESS = 3

    # Default incoming-frame size cap (decoded bytes). Generous enough for a
    # large initial SyncStep2, small enough to bound a single message's
    # allocation/parse cost. Override per channel with `max_frame_bytes`.
    DEFAULT_MAX_FRAME_BYTES = 8 * 1024 * 1024

    # After this many times the *same* update is rejected as a causal gap on one
    # connection, stop resyncing and instead settle it (ack) + drop it. A gap
    # that survives repeated resyncs is unhealable — its missing dependency is
    # gone for good (a permanently-orphaned pending struct) — and resyncing it
    # forever just amplifies the client's retransmit loop. A healable gap heals
    # within a resync or two, well under this. Override with `gap_strike_limit`;
    # set to nil to disable (always resync). See `sync_gap_strike`.
    DEFAULT_GAP_STRIKE_LIMIT = 3

    # Cap on distinct gappy updates tracked per connection, so a client can't
    # grow the strike table without bound by sending endless distinct gaps.
    GAP_STRIKE_MAX_KEYS = 64

    def self.included(base)
      base.extend(ClassMethods)
      # Durable strike state under AnyCable. Each AnyCable RPC command gets a
      # fresh channel instance, so a plain ivar resets every message and the
      # unhealable-gap drop would never trip. anycable-rails' state_attr_accessor
      # persists the value into the subscription's istate, which anycable-go
      # round-trips on every command — so strikes accumulate there too. On plain
      # ActionCable (anycable-rails loaded but not serving) the accessor behaves
      # like attr_accessor; without anycable-rails we fall back to an ivar.
      # NOTE: anycable-rails must be loaded before the channel class is defined
      # for this declaration to take effect (standard Bundler.require order).
      base.state_attr_accessor :yrby_gap_strikes if base.respond_to?(:state_attr_accessor)
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

      # Number of times the same update may be rejected as a gap on one
      # connection before it is settled + dropped instead of resynced again.
      # Defaults to DEFAULT_GAP_STRIKE_LIMIT; set to nil to always resync.
      # A limit below 2 is rejected: strike 1 must send a resync (the heal
      # attempt) before any drop, or a first-sight healable gap would be
      # settled with no recovery ever attempted.
      def gap_strike_limit(limit = :__unset__)
        # Combined reader/writer; the sentinel keeps nil a real value (disables the drop).
        unless limit == :__unset__
          raise ArgumentError, "gap_strike_limit must be nil or >= 2 (got #{limit.inspect})" if limit && limit < 2

          @gap_strike_limit = limit
        end
        return @gap_strike_limit if defined?(@gap_strike_limit)

        superclass.respond_to?(:gap_strike_limit) ? superclass.gap_strike_limit : DEFAULT_GAP_STRIKE_LIMIT
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
      sync_transmit(sync_load_doc.sync_step1)
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

    # Ask this connection's client to resync: re-send SyncStep1 carrying the
    # server's current (gap-free) state vector. The client replies SyncStep2
    # with everything the server is missing, delivered as one causally-complete
    # delta, which heals the gap that triggered the resync.
    def sync_request_resync(doc)
      sync_transmit(doc.sync_step1)
    end

    # Reliable delivery: acknowledge an accepted update back to the sending
    # connection. An ack-aware client tags each outgoing update with an "id"
    # and retains it until the matching `{ "ack" => id }` returns, retransmitting
    # on a timer or reconnect; idempotent CRDT apply makes resends free. Acks
    # are sent only after the update has been durably recorded, or when a retry
    # is already present in the durable store.
    def sync_send_ack(id, outcome)
      return if id.nil?
      # :dropped_unhealable settles a permanently-orphaned retry so the client
      # stops retransmitting it (it was never going to integrate anywhere). The
      # envelope carries "dropped" so the client can tell "durably recorded"
      # from "abandoned" and surface it, instead of silently reporting synced
      # over lost data. Clients that don't know the key ignore it.
      return unless %i[recorded applied dropped_unhealable].include?(outcome)

      # The braces are required: a bare hash would bind to transmit's `via:`
      # keyword instead of its positional data argument.
      if outcome == :dropped_unhealable
        transmit({ "ack" => id, "dropped" => true })
      else
        transmit({ "ack" => id })
      end
    end

    # Count consecutive gap rejections of `update` on this connection, returning
    # the new count. Keyed by update content (SHA-256) so independent gaps track
    # separately — a slow-to-heal legit gap must not push an unrelated one toward
    # the drop.
    #
    # Where the state lives:
    # - Plain ActionCable reuses the channel instance across a connection's
    #   messages, so an ivar accumulates (guarded by a mutex: ActionCable
    #   dispatches messages to a worker pool, so two receives on one instance
    #   can run concurrently).
    # - Under AnyCable each RPC command gets a fresh instance, so the table is
    #   persisted via anycable-rails' `state_attr_accessor` (istate), which
    #   anycable-go round-trips on every command. See `self.included`.
    def sync_gap_strike(update)
      key = Digest::SHA256.hexdigest(update)
      sync_gap_strike_mutex.synchronize do
        strikes = sync_read_gap_strikes
        # Bound the table so endless *distinct* gaps can't grow it without
        # limit. Evict a single lowest-count entry, and only when inserting a
        # genuinely new key: clearing wholesale would let a client cycling 64
        # distinct gaps reset every tracked strike (defense bypass) and would
        # starve a legitimate hot key.
        if !strikes.key?(key) && strikes.size >= GAP_STRIKE_MAX_KEYS
          strikes.delete(strikes.min_by { |_, count| count }.first)
        end
        strikes[key] = strikes.fetch(key, 0) + 1
        sync_write_gap_strikes(strikes)
        strikes[key]
      end
    end

    # A gap that finally records has healed: free its strike slot so it can't
    # bias a future eviction and the table reflects only live gaps.
    def sync_clear_gap_strike(update)
      sync_gap_strike_mutex.synchronize do
        strikes = sync_read_gap_strikes
        next_key = Digest::SHA256.hexdigest(update)
        if strikes.key?(next_key)
          strikes.delete(next_key)
          sync_write_gap_strikes(strikes)
        end
      end
    end

    def sync_gap_strike_mutex
      @sync_gap_strike_mutex ||= Mutex.new
    end

    # Strike-table storage: istate-backed under AnyCable (survives the
    # per-command fresh instance), plain ivar otherwise. Values round-trip JSON
    # under AnyCable, so the table is a plain Hash of hex-digest => Integer.
    def sync_read_gap_strikes
      if respond_to?(:yrby_gap_strikes)
        (yrby_gap_strikes || {}).to_h { |k, v| [k.to_s, v.to_i] }
      else
        @gap_strikes || {}
      end
    end

    def sync_write_gap_strikes(strikes)
      if respond_to?(:yrby_gap_strikes=)
        self.yrby_gap_strikes = strikes
      else
        @gap_strikes = strikes
      end
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

    # Stateless per message: any process can handle any document. A client's
    # SyncStep1 is answered from the store, document changes are recorded durably
    # before relay and then broadcast, and awareness is relayed best-effort.
    # Echoing back to the sender is harmless, since the CRDT apply is idempotent.
    #
    # Returns an outcome symbol for the reliable-delivery ack: :recorded when a
    # document update was durably recorded and relayed, :gap when it was
    # rejected for a resync, :dropped_unhealable when a repeatedly-gapped update
    # is settled + dropped, :noop for everything else.
    def sync_handle_frame(encoded, bytes)
      sync_validate_required_hooks!
      sync_validate_key!

      case Y.message_kind(bytes)
      when MSG_KIND_SYNC_STEP1
        result = sync_load_doc.handle_sync_message(bytes)
        sync_transmit(result[2])
        :noop
      when MSG_KIND_UPDATE
        sync_handle_update(encoded, bytes)
      when MSG_KIND_AWARENESS
        sync_distribute(encoded)
        :noop
      else
        :noop
      end
    end

    # The document-update arm of sync_handle_frame: gate on causal readiness
    # (with the unhealable-gap strike defense), skip-but-rebroadcast retries,
    # and record-before-distribute for genuinely new content.
    def sync_handle_update(encoded, bytes)
      update = Y.update_from_message(bytes)
      return :noop unless update

      # Rebuild from the store (O(history) per update; snapshot in on_load if
      # that cost bites).
      doc = sync_load_doc

      # Don't record a causally-incomplete update; resync so the gap heals as
      # one complete delta. But a gap that survives repeated resyncs is
      # unhealable (its missing dependency is gone for good) — resyncing it
      # forever just feeds the client's retransmit loop. After
      # `gap_strike_limit` rejections of the same update, settle it (ack via
      # the :dropped_unhealable outcome) and drop it instead.
      unless doc.update_ready?(update)
        limit = self.class.gap_strike_limit
        if limit && sync_gap_strike(update) >= limit
          sync_log_drop(:info, "dropping unhealable gappy update after #{limit} strikes")
          return :dropped_unhealable
        end
        sync_request_resync(doc)
        return :gap
      end

      # A lost-ack retry: already recorded, so skip on_change — but DO
      # re-broadcast. If the first attempt died between record and broadcast,
      # this retry is the only path left to the live subscribers. Duplicate
      # broadcasts are free (CRDT apply is idempotent).
      unless doc.update_advances?(update)
        sync_clear_gap_strike(update) # a formerly-gappy update that healed
        sync_distribute(encoded)
        return :applied
      end

      sync_record_change(update) # record before relay
      sync_clear_gap_strike(update) # a gap that finally recorded has healed
      sync_distribute(encoded)
      :recorded
    end

    # Build a fresh document from the durable store (on_load). Callers validate
    # the hooks first, so on_load is present; a nil state means a fresh document.
    def sync_load_doc
      doc = Y::Doc.new
      state = instance_exec(@sync_key, &self.class.on_load)
      doc.apply_update(state) if state
      doc
    end

    def sync_stream_name
      "yrby:#{@sync_key}"
    end

    def sync_awareness_stream_name
      "#{sync_stream_name}:awareness"
    end

    # Invoke the on_change recorder in this channel instance's context
    # (instance_exec) so it can reach the channel's own methods. Mirrors how
    # sync_load_doc fetches and runs on_load.
    def sync_record_change(update)
      instance_exec(@sync_key, update, &self.class.on_change)
    end
  end
end
