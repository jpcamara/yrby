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

      # Valid causal_gap_policy values, in order of increasing willingness to
      # take custody of a causally-incomplete update.
      CAUSAL_GAP_POLICIES = %i[reject accept_strict accept].freeze

      # How to handle a causally-incomplete ("gappy") update — one whose
      # causally-prior update the store hasn't seen. Defaults to :reject.
      #
      # :reject (default) — Don't record it. Ask the sender to resync so the gap
      #   heals as one complete delta. The durable log never holds pending
      #   content, and an open gap surfaces loudly as resync traffic. This is the
      #   original behavior; it rebuilds the doc from the store on every update to
      #   detect the gap.
      #
      # :accept_strict — Record the gappy update immediately (as a pending
      #   struct) but do NOT ack it until it integrates. The sender keeps
      #   retransmitting it, so an unhealed gap still self-signals as retry
      #   traffic, while the edit is durable the moment it arrives. Rebuilds the
      #   doc to decide readiness, like :reject.
      #
      # :accept — Record and ack the gappy update immediately (ack-on-durable).
      #   This inverts the write path: it does NOT rebuild the doc — it appends,
      #   relays, and acks, delegating dedup to the store's idempotency (see
      #   on_change). Fastest and cheapest, but an unhealed gap is silent (it
      #   sits as pending, never served), so lean on the repair loop (a joiner is
      #   asked to supply missing deps) and on pending-depth monitoring
      #   (see on_gap).
      #
      # Serving is gap-free under EVERY policy: handle_sync_message and
      # compacted_state_update exclude pending, so a peer never receives
      # un-integrable content. The policy changes only what the server *stores*
      # and *acks*, never what it *serves*.
      #
      # Both accept modes require a LOSSLESS store: on_load must return state that
      # preserves pending (encode_state_as_update, or a replayed raw append log),
      # and any compaction must be guarded with `doc.pending?` —
      # compacted_state_update strips pending and would drop an open gap.
      def causal_gap_policy(value = :__unset__)
        unless value == :__unset__
          unless CAUSAL_GAP_POLICIES.include?(value)
            raise ArgumentError,
                  "causal_gap_policy must be one of #{CAUSAL_GAP_POLICIES.inspect}, got #{value.inspect}"
          end
          @causal_gap_policy = value
        end
        return @causal_gap_policy if defined?(@causal_gap_policy)

        superclass.respond_to?(:causal_gap_policy) ? superclass.causal_gap_policy : :reject
      end

      # Optional observability hook, fired when the server observes a causal gap
      # (a pending struct) in an accept mode — at record time in :accept_strict,
      # and at join/serve time whenever a loaded doc is still pending. Called with
      # (key) in the channel instance's context (instance_exec). Use it to emit a
      # metric (pending-document count, gap age) so an unhealed gap is visible;
      # accept mode heals silently, so this is how you replace the resync-storm
      # signal reject mode gave you for free. Errors in the hook are swallowed so
      # observability can never break frame handling.
      def on_gap(&block)
        @on_gap = block if block
        return @on_gap if defined?(@on_gap) && @on_gap

        superclass.respond_to?(:on_gap) ? superclass.on_gap : nil
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

      # The opening handshake is also the gap-repair prompt: sending our SyncStep1
      # asks the joining client for everything beyond our integrated state, which
      # is exactly the missing dependency an accept-mode gap is waiting on. If a
      # live client has it, the join heals the gap. We only surface it (on_gap) —
      # the handshake below already does the soliciting.
      doc = sync_load_doc
      sync_transmit(doc.sync_step1)
      sync_observe_gap if doc.pending? && self.class.causal_gap_policy != :reject
    end

    # Call from `receive`. Applies the client's message, replies directly
    # when the protocol calls for it, and relays document/awareness changes
    # to the other subscribers.
    #
    # Reliable delivery: document updates carry an "id", and the server replies
    # `{ "ack" => id }` once the update has been durably recorded. The
    # causal_gap_policy decides what happens to a gappy update: :reject resyncs
    # and never acks it; :accept_strict records it but acks only once it
    # integrates; :accept records and acks it immediately (ack-on-durable).
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

    # Accept modes only: a causal gap was observed (recorded in :accept_strict, or
    # found still-pending at serve/join time). It's durable but won't appear in
    # served state until its missing dependency arrives and heals it. In :reject a
    # gap surfaced loudly as a resync storm; in accept modes it's quiet, so make it
    # findable: log at info, and fire the on_gap hook so the app can emit a metric
    # (pending-document count, gap age). Errors in the hook are swallowed —
    # observability must never break frame handling.
    def sync_observe_gap
      logger.info do
        parts = ["key=#{@sync_key.inspect}"]
        parts << sync_log_context_safe
        "[yrby] causal gap present (pending until its dependency arrives): #{parts.compact.join(" ")}"
      end

      return unless (hook = self.class.on_gap)

      begin
        instance_exec(@sync_key, &hook)
      rescue StandardError => e
        logger.error { "[yrby] on_gap hook raised (#{e.class}); continuing: key=#{@sync_key.inspect}" }
      end
    end

    # Accept modes only: if the loaded doc still holds a gap, ask this client to
    # supply the missing dependency by sending our SyncStep1 (it replies with
    # everything beyond our integrated state). This is the repair loop for an
    # unhealed gap: any client that has the missing update heals it on contact.
    # A truly-unhealable gap (no live client has the dependency) will not heal
    # here — it needs operator action, which is what on_gap surfaces.
    def sync_solicit_repair(doc)
      return if self.class.causal_gap_policy == :reject
      return unless doc.pending?

      sync_request_resync(doc)
      sync_observe_gap
    end

    # Does this update carry content the loaded doc doesn't already hold (as an
    # integrated or pending struct)? Used for the gappy path in :accept_strict,
    # where update_advances? is unreliable (it detects only the first pending
    # struct, so a second gap reads as a duplicate). Prefers the native
    # update_adds_content? primitive when the core provides it; otherwise falls
    # back to a lossless full-state comparison (encode_state_as_update keeps
    # pending) on a throwaway copy.
    def sync_adds_content?(doc, update)
      return doc.update_adds_content?(update) if doc.respond_to?(:update_adds_content?)

      before = doc.encode_state_as_update
      probe = Y::Doc.new
      probe.apply_update(before)
      probe.apply_update(update)
      before != probe.encode_state_as_update
    end

    # sync_log_context, guarded: a broken context hook must surface in the log,
    # not take down frame handling.
    def sync_log_context_safe
      sync_log_context
    rescue StandardError => e
      "log-context-error=#{e.class}"
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
    # document update was durably recorded and relayed, :applied for an
    # already-recorded retry (re-broadcast and acked), :gap when a gappy update
    # was rejected for a resync, :recorded_pending when a gappy update was
    # recorded but not yet acked (accept_strict), :noop for everything else.
    def sync_handle_frame(encoded, bytes)
      sync_validate_required_hooks!
      sync_validate_key!

      case Y.message_kind(bytes)
      when MSG_KIND_SYNC_STEP1
        doc = sync_load_doc
        result = doc.handle_sync_message(bytes)
        sync_transmit(result[2])         # integrated-only state (never pending)
        sync_solicit_repair(doc)         # if a gap is open, ask this client to fill it
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

    # Apply one document update under the channel's causal_gap_policy. Returns the
    # reliable-delivery outcome (see sync_handle_frame for the contract).
    def sync_handle_document_update(update, encoded)
      if self.class.causal_gap_policy == :accept
        sync_accept_update(encoded, update)
      else
        sync_gated_update(update, encoded)
      end
    end

    # :accept — ack-on-durable, inverted write path. No doc rebuild and no gap
    # check: record (the store dedups by idempotency), relay, ack. An open gap
    # heals via the join handshake (sync_solicit_repair) and is surfaced by on_gap
    # at serve time, not here.
    def sync_accept_update(encoded, update)
      sync_record_change(update) # record before relay; on_change must be idempotent
      sync_distribute(encoded)
      :recorded
    end

    # :reject and :accept_strict — rebuild from the store to decide readiness.
    # (O(history) per update; snapshot in on_load if that cost bites.)
    def sync_gated_update(update, encoded)
      doc = sync_load_doc
      ready = doc.update_ready?(update)

      # A causal gap. :reject refuses it and resyncs so it heals as one complete
      # delta. :accept_strict records it (below) but won't ack until it
      # integrates. Serving stays gap-free either way.
      if !ready && self.class.causal_gap_policy == :reject
        sync_request_resync(doc)
        return :gap
      end

      # Does the update carry content the store doesn't already hold? For a ready
      # update update_advances? answers cheaply; for a gappy one it can't (it
      # flips false->true only on the FIRST pending struct, so a second gap reads
      # as a duplicate), so use sync_adds_content? there.
      adds_content = ready ? doc.update_advances?(update) : sync_adds_content?(doc, update)

      # A duplicate we've already recorded: skip on_change — but DO re-broadcast.
      # If the first attempt died between record and broadcast, this retry is the
      # only path left to the live subscribers. Duplicate broadcasts are free
      # (CRDT apply is idempotent). Ack a *ready* duplicate (a genuine
      # already-integrated retry), but NOT a still-gappy one: acking a
      # still-pending retry would tell the sender to stop retransmitting before
      # the update integrates, defeating :accept_strict's self-signaling — so a
      # gappy duplicate stays unacked, exactly like the fresh gap below.
      unless adds_content
        sync_distribute(encoded)
        return ready ? :applied : :recorded_pending
      end

      return sync_record_ready(update, encoded) if ready

      # :accept_strict gappy: record and relay, but do NOT ack. The sender keeps
      # retransmitting until the update integrates, so the gap self-signals as
      # retry traffic and heals when its dependency lands. Observe only AFTER the
      # gap is durably recorded, so a failed on_change (which raises and rejects
      # the update) never logs or metrics a persistence that didn't happen.
      sync_record_change(update) # record before relay
      sync_observe_gap
      sync_distribute(encoded)
      :recorded_pending
    end

    def sync_record_ready(update, encoded)
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
