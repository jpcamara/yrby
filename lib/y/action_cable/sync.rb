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

      # Whether to accept and record causally-gapped updates instead of
      # rejecting them for a resync. Defaults to false (reject mode).
      #
      # Reject mode (default): a causally-incomplete update is not recorded; the
      # server asks the sender to resync so the gap heals as one complete delta,
      # and the durable log never holds pending content. An open gap surfaces
      # loudly as resync traffic.
      #
      # Accept mode (true): a gappy update is recorded immediately. yrs parks it
      # as a pending struct that heals when its missing dependency arrives — via
      # that dependency's own reliable-delivery retransmit — with no resync round
      # trip. A received edit is durable even if the sender dies before a resync
      # would have completed. Serving is gap-free in both modes
      # (handle_sync_message / compacted_state_update exclude pending), so a peer
      # never receives un-integrable content.
      #
      # Accept mode has two costs, both required to run it safely:
      #
      #   1. The durable store MUST preserve pending across load/save. on_load
      #      has to return lossless state — encode_state_as_update, or a replayed
      #      raw append log — and any compaction must NOT run
      #      compacted_state_update while `doc.pending?` (that strips the pending
      #      struct and loses the gap). Guard compaction with `doc.pending?`.
      #   2. An unhealed gap is silent (it sits as pending, never served) rather
      #      than loud (a resync storm). Monitor pending depth in the store; the
      #      concern also logs each recorded gap (see sync_log_gap) so an
      #      unhealed gap is findable.
      def accept_causal_gaps(value = :__unset__)
        @accept_causal_gaps = value unless value == :__unset__
        return @accept_causal_gaps if defined?(@accept_causal_gaps)

        superclass.respond_to?(:accept_causal_gaps) ? superclass.accept_causal_gaps : false
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
    # `{ "ack" => id }` once the update has been durably recorded. By default a
    # causally-gapped update is not acked; it gets a resync instead, so the
    # client retransmits until the update lands. With `accept_causal_gaps` set,
    # a gappy update is recorded (as pending) and acked immediately.
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

    # Accept mode only (accept_causal_gaps): a causally-gapped update was just
    # recorded. It's durable but won't appear in served state until its missing
    # dependency arrives and heals it. In reject mode a gap surfaced loudly as a
    # resync storm; here it's silent, so log it at info (naming the document and
    # any sync_log_context) to keep unhealed gaps findable. Pair this with
    # monitoring pending depth in the store.
    def sync_log_gap
      logger.info do
        parts = ["key=#{@sync_key.inspect}"]
        context = begin
          sync_log_context
        rescue StandardError => e
          "log-context-error=#{e.class}"
        end
        parts << context if context
        "[yrby] recorded causally-gapped update (pending until its dependency arrives): #{parts.join(" ")}"
      end
    end

    # Accept mode only: does this causally-gapped update carry content the loaded
    # doc doesn't already hold (as an integrated or pending struct)?
    # update_advances? can't answer for a doc that already holds pending — it
    # detects only the first pending struct, so a second gap would read as a
    # duplicate and be dropped. Compare lossless full state
    # (encode_state_as_update keeps pending) before and after applying on a
    # throwaway copy. Costs a full encode; accept mode opts into it, and a native
    # "adds any struct?" primitive could replace it later.
    def sync_gappy_adds_content?(doc, update)
      before = doc.encode_state_as_update
      probe = Y::Doc.new
      probe.apply_update(before)
      probe.apply_update(update)
      before != probe.encode_state_as_update
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
    # rejected for a resync, :noop for everything else.
    def sync_handle_frame(encoded, bytes)
      sync_validate_required_hooks!
      sync_validate_key!

      case Y.message_kind(bytes)
      when MSG_KIND_SYNC_STEP1
        result = sync_load_doc.handle_sync_message(bytes)
        sync_transmit(result[2])
        :noop
      when MSG_KIND_UPDATE
        update = Y.update_from_message(bytes)
        return :noop unless update

        sync_handle_document_update(update, encoded)
      when MSG_KIND_AWARENESS
        sync_distribute(encoded)
        :noop
      else
        :noop
      end
    end

    # Apply one document update: detect a causal gap, dedup a retry, record, and
    # relay. Returns the reliable-delivery outcome (:recorded, :applied, :gap, or
    # :noop). See sync_handle_frame for the outcome contract.
    def sync_handle_document_update(update, encoded)
      # Rebuild from the store (O(history) per update; snapshot in on_load if
      # that cost bites).
      doc = sync_load_doc
      ready = doc.update_ready?(update)

      # A causally-incomplete update. In reject mode (the default) don't record
      # it; resync instead so the gap heals as one complete delta. In accept
      # mode (accept_causal_gaps) fall through and record it as a pending struct
      # that heals when its missing dependency arrives. Serving stays gap-free
      # either way, so a peer never receives un-integrable content.
      if !ready && !self.class.accept_causal_gaps
        sync_request_resync(doc)
        return :gap
      end

      # Does the update carry content the store doesn't already hold? For a ready
      # update, update_advances? answers cheaply. For a gappy one it can't:
      # update_advances? flips false->true only on the FIRST pending struct, so a
      # second gap on an already-pending doc reads as a duplicate and would be
      # silently dropped. Compare lossless full state there instead (see
      # sync_gappy_adds_content?). Relies on on_load being lossless so an
      # already-pending gap isn't re-recorded on every resend.
      adds_content = ready ? doc.update_advances?(update) : sync_gappy_adds_content?(doc, update)

      # A lost-ack retry / duplicate: already recorded, so skip on_change — but DO
      # re-broadcast. If the first attempt died between record and broadcast, this
      # retry is the only path left to the live subscribers. Duplicate broadcasts
      # are free (CRDT apply is idempotent).
      unless adds_content
        sync_distribute(encoded)
        return :applied
      end

      # Accept mode only: a newly-recorded gap is durable but invisible until it
      # heals. In reject mode a gap was a resync storm; here it's silent, so log
      # it to keep unhealed gaps findable.
      sync_log_gap unless ready
      sync_record_change(update) # record before relay
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
