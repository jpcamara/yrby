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
  #     include Y::ActionCable
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
  #
  #     private
  #
  #     # Required. The default refuses everyone; nothing syncs until the
  #     # channel says who may. Return true deliberately for public documents.
  #     def authorized?(key)
  #       current_user&.member_of?(key)
  #     end
  #   end
  #
  # There is no unsubscribe hook: the server keeps no per-connection document or
  # presence state, so a disconnect needs no server-side cleanup.
  #
  # The concern is store-backed: every document update is recorded through
  # `on_change` before it is broadcast or acked, and documents rebuild from
  # `on_load` whenever state is served. No authoritative document state is
  # kept in ActionCable process memory.
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

    # The storage a channel gets without declaring hooks: the gem's own
    # models, the way Action Text defaults to its rich_texts table. Only in
    # play when yrby-rails' models are actually loadable, so the concern used
    # outside Rails still fails closed until hooks are declared.
    DEFAULT_STORAGE = {
      on_load: ->(key) { Y::Document.load_state(key) },
      on_change: ->(key, update) { Y::Document.append(key, update) }
    }.freeze

    def self.default_hook(name)
      DEFAULT_STORAGE[name] if Object.const_defined?("Y::Document")
    end

    module ClassMethods
      # Load persisted document state. Called once per key with (key); return a
      # binary Y.js update (or nil for a fresh document). Runs in the channel
      # instance's context (instance_exec). Defaults to Y::Document storage
      # when yrby-rails' models are present; declare a block to point storage
      # elsewhere.
      def on_load(&block)
        @on_load = block if block
        return @on_load if defined?(@on_load) && @on_load

        superclass.respond_to?(:on_load) ? superclass.on_load : Sync.default_hook(:on_load)
      end

      # Record every document change durably before it is applied or
      # distributed. Called synchronously with (key, update), where update is
      # the exact CRDT delta. If the block raises, the change is rejected:
      # neither acknowledged nor broadcast to other subscribers.
      #
      # Runs in the channel instance's context (instance_exec). Fires from within
      # sync_receive. Defaults to Y::Document storage when yrby-rails' models
      # are present.
      def on_change(&block)
        @on_change = block if block
        return @on_change if defined?(@on_change) && @on_change

        superclass.respond_to?(:on_change) ? superclass.on_change : Sync.default_hook(:on_change)
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

      # Optional observability hook, fired at join/serve time whenever the
      # loaded document still holds a causal gap (a pending struct). Called
      # with (key) in the channel instance's context (instance_exec). Use it
      # to emit a metric (pending-document count, gap age) so an unhealed gap
      # is visible. Errors in the hook are swallowed so observability can
      # never break frame handling.
      def on_gap(&block)
        @on_gap = block if block
        return @on_gap if defined?(@on_gap) && @on_gap

        superclass.respond_to?(:on_gap) ? superclass.on_gap : nil
      end
    end

    # Call from `subscribed`. Authorizes the subscriber (see #authorized?),
    # then streams broadcasts for this document and transmits the server's
    # opening handshake (SyncStep1 from the store). Rejects and returns false
    # when authorized? refuses — including always, until the channel defines it.
    def sync_subscribed(key)
      @sync_key = key.to_s
      sync_validate_required_hooks!
      unless authorized?(@sync_key)
        sync_reject_unauthorized
        return false
      end

      # The document stream is never whisper-enabled; under AnyCable we also
      # subscribe an awareness stream with `whisper: true`, scoping the client-to-
      # client path to ephemeral presence rather than the durable document stream.
      stream_from sync_stream_name
      stream_from sync_awareness_stream_name, whisper: true if respond_to?(:whispers_to)

      # The opening handshake is also the gap-repair prompt: sending our SyncStep1
      # asks the joining client for everything beyond our integrated state, which
      # is exactly the missing dependency an open gap is waiting on. If a live
      # client has it, the join heals the gap. We only surface it (on_gap); the
      # handshake below already does the soliciting.
      doc = sync_load_doc
      sync_transmit(doc.sync_step1)
      sync_observe_gap if doc.pending?
    end

    # Call from `receive`. Applies the client's message, replies directly
    # when the protocol calls for it, and relays document/awareness changes
    # to the other subscribers.
    #
    # Reliable delivery: document updates carry an "id", and the server replies
    # `{ "ack" => id }` once the update has been durably recorded. A causally-
    # incomplete update is recorded and acked like any other; it stays pending
    # (durable, invisible in the document) until its missing dependency
    # arrives.
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

    # Whether this subscriber may sync the document named by `key`. The
    # default refuses everyone: authorization is an explicit decision a
    # channel makes, not something it gets by omission. Override it:
    #
    #   def authorized?(key)
    #     current_user&.member_of?(key)
    #   end
    #
    # Runs before any stream is opened or state served, with the connection's
    # context available (current_user, params, ...). Return true deliberately
    # for documents that are genuinely public.
    def authorized?(_key)
      false
    end

    # The subscription was refused. When the refusal came from the default
    # authorized? (the channel never defined one), say how to fix it — that is
    # the difference between fail-closed and mysteriously broken.
    def sync_reject_unauthorized
      logger.info do
        hint = if method(:authorized?).owner == Sync
                 "; no authorized? defined — define authorized?(key) in this channel, " \
                   "returning true deliberately for public documents"
               end
        "[yrby] subscription rejected key=#{@sync_key.inspect}#{hint}"
      end
      reject
    end

    # Reliable delivery: acknowledge an accepted update back to the sending
    # connection. An ack-aware client tags each outgoing update with an "id"
    # and retains it until the matching `{ "ack" => id }` returns,
    # retransmitting on a timer or reconnect; applying a CRDT update twice is
    # safe. Acks are sent only after the update has been durably recorded.
    def sync_send_ack(id, outcome)
      return if id.nil?
      return unless outcome == :recorded

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

    # A causal gap was observed at join/serve time: the update is durable but
    # its content stays invisible in the document until its missing dependency
    # arrives and heals it. Healing is quiet, so make the open gap findable: log at info,
    # and fire the on_gap hook so the app can emit a metric (pending-document
    # count, gap age). Errors in the hook are swallowed; observability must
    # never break frame handling.
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
            "that never happened, and a cold load would lose the edit. (With yrby-rails' " \
            "models installed these default to Y::Document storage.)"
    end

    # Fail closed when no document key is set (typically: AnyCable rebuilt the
    # channel instance and the app forgot to pass `key` to sync_receive).
    # Proceeding would record under nil, broadcast to a stream nobody
    # subscribes to, and still ack; the client believes the edit was
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
    # Returns an outcome symbol for the reliable-delivery ack: :recorded when
    # a document update was durably recorded and relayed (a lost-ack retry
    # records again; the store tolerates duplicates), :noop for everything
    # else.
    def sync_handle_frame(encoded, bytes)
      sync_validate_required_hooks!
      sync_validate_key!

      case Y.message_kind(bytes)
      when MSG_KIND_SYNC_STEP1
        doc = sync_load_doc
        result = doc.handle_sync_message(bytes)
        sync_transmit(result[2]) # full state, pending included
        sync_observe_gap if doc.pending?
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

    # Ack-on-durable, with no doc rebuild and no gap check on the write
    # path: record (before relay), relay, ack. A causally-incomplete update is
    # recorded as a pending struct like any other edit and served onward like
    # one (a peer parks and heals it the same way this doc does). The gap
    # heals when its missing dependency arrives: its own sender retransmits
    # it until acked, and every join or reconnect handshake has the client
    # send everything beyond the server's integrated state. An open gap is
    # surfaced by on_gap at join/serve time. on_change must tolerate
    # duplicates: a lost-ack retry records again.
    def sync_handle_document_update(update, encoded)
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
