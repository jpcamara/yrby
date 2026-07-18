# frozen_string_literal: true

module Y
  module Sync
    # The transport-neutral yrby sync core: the y-websocket protocol state
    # machine, with no transport attached.
    #
    # `Y::ActionCable::Sync` is a thin adapter over this — it decodes the cable
    # envelope, calls {#handle}, and routes the {Result} back through
    # `transmit` / `ActionCable.server.broadcast`. Those routing calls are the
    # only thing that ties collaboration to ActionCable. Any transport that can
    # deliver a reply to one client and relay a frame to the rest can carry the
    # same protocol: a raw WebSocket, or REST plus a pub/sub bus (Discourse's
    # MessageBus), for instance.
    #
    # The engine holds no per-connection or per-document state. Every call
    # rebuilds the document from the store through the `load` hook, so one
    # engine is safe to share across connections, requests, and threads — the
    # same statelessness that lets any process serve any document.
    #
    #   engine = Y::Sync::Engine.new(
    #     load:   ->(key)         { MyStore.load(key) },      # bytes, or nil
    #     change: ->(key, update) { MyStore.append(key, update) }
    #   )
    #
    # Reliability (ack-tracked delivery, causal-gap detection, integrated-only
    # serving) lives here, because it is the yrs calls themselves —
    # `update_ready?`, `update_advances?`, `handle_sync_message`,
    # `compacted_state_update`.
    class Engine
      # Frame kinds from Y.message_kind. Its other codes (0 for a drop, 4 for
      # an awareness query) fall through to a no-op.
      MSG_KIND_SYNC_STEP1 = 1
      MSG_KIND_UPDATE = 2
      MSG_KIND_AWARENESS = 3

      # What the transport should do with a handled frame. Exactly one of
      # `reply` / `broadcast` is set in every branch, but they are separate
      # fields so a transport routes them without re-inspecting the frame.
      #
      # - `reply`     raw protocol bytes to send back to THIS client only (a
      #               SyncStep2 answering a SyncStep1, or a resync request), or
      #               nil.
      # - `broadcast` the caller-supplied encoded frame to relay to the OTHER
      #               clients on this document, or nil.
      # - `ack`       the reliable-delivery outcome: :recorded (durably stored
      #               and relayed), :applied (a lost-ack retry, re-relayed but
      #               not re-recorded), :gap (rejected, resync requested), or
      #               :noop. See {#ack?}.
      Result = Data.define(:reply, :broadcast, :ack) do
        # Reliable-delivery clients are acked only once an update is durably
        # recorded (:recorded), or on an already-present retry that was still
        # relayed (:applied). A gap or a no-op is never acked.
        def ack?
          %i[recorded applied].include?(ack)
        end
      end

      # `load`   — called with (key); returns a binary Y.js update to rebuild
      #            the document, or nil for a fresh one.
      # `change` — called with (key, update) to record a delta durably. Runs
      #            before the update is acked or relayed; if it raises, the
      #            change is rejected (neither happens) and the raise
      #            propagates to the caller.
      def initialize(load:, change:)
        @load = load
        @change = change
      end

      # The opening handshake frame for a joining client over a bidirectional
      # transport: the server's SyncStep1 (its state vector). The client
      # answers with a SyncStep2 carrying anything the server is missing. This
      # is what `Y::ActionCable::Sync` transmits from `subscribed`.
      def sync_step1(key)
        load_doc(key).sync_step1
      end

      # The current document state as one gap-free update, for a joiner over a
      # request/response transport (REST) that applies it directly rather than
      # diffing. `compacted_state_update` (not `encode_state_as_update`) so a
      # joiner never receives pending structs it cannot integrate.
      def full_state(key)
        load_doc(key).compacted_state_update
      end

      # Handle one decoded frame for `key` and return a {Result}. `encoded` is
      # the frame in whatever form the transport relays (the cable adapter
      # passes the base64 string, so an echoed broadcast matches the wire
      # format); `bytes` is its decoded form, which the protocol reads. The
      # engine relays `encoded` verbatim and never inspects the transport's
      # encoding.
      def handle(key, encoded, bytes)
        case Y.message_kind(bytes)
        when MSG_KIND_SYNC_STEP1
          # Answer the client's state vector with an integrated-only SyncStep2
          # (handle_sync_message never serves pending structs).
          reply = load_doc(key).handle_sync_message(bytes)[2]
          Result.new(reply: reply, broadcast: nil, ack: :noop)
        when MSG_KIND_UPDATE
          handle_update(key, encoded, bytes)
        when MSG_KIND_AWARENESS
          # Ephemeral presence: relay, never record.
          Result.new(reply: nil, broadcast: encoded, ack: :noop)
        else
          noop
        end
      end

      private

      def handle_update(key, encoded, bytes)
        update = Y.update_from_message(bytes)
        return noop unless update

        # Rebuild from the store (O(history) per update; snapshot in `load` if
        # that cost bites).
        doc = load_doc(key)

        # Don't record a causally-incomplete update; request a resync so the
        # gap heals as one complete delta.
        return Result.new(reply: doc.sync_step1, broadcast: nil, ack: :gap) unless doc.update_ready?(update)

        # A lost-ack retry: already recorded, so skip `change` — but DO
        # re-relay. If the first attempt died between record and broadcast,
        # this retry is the only path left to the live subscribers. Duplicate
        # relays are free (CRDT apply is idempotent).
        return Result.new(reply: nil, broadcast: encoded, ack: :applied) unless doc.update_advances?(update)

        @change.call(key, update) # record before relay
        Result.new(reply: nil, broadcast: encoded, ack: :recorded)
      end

      def load_doc(key)
        doc = Y::Doc.new
        state = @load.call(key)
        doc.apply_update(state) if state
        doc
      end

      def noop
        Result.new(reply: nil, broadcast: nil, ack: :noop)
      end
    end
  end
end
