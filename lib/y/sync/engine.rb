# frozen_string_literal: true

module Y
  module Sync
    # The transport-neutral yrby sync core: the y-websocket protocol state
    # machine, with no transport attached.
    #
    # `Y::ActionCable::Sync` decodes the cable envelope, calls {#handle}, and
    # routes the {Result} through `transmit` and `ActionCable.server.broadcast`.
    # Another transport supplies its own routing for the same Results.
    #
    # The engine adds no mutable protocol state. Document frames rebuild from
    # the store through the `load` hook, which is what lets any process serve
    # any document. Sharing one engine is therefore only as safe as its
    # hooks: they must be thread-safe, and must not close over a single
    # connection's state. Two concurrent calls can also classify the same
    # delta as new and both call `change`, so a recorder must tolerate
    # duplicates. The ActionCable adapter builds one engine per channel
    # instance, whose hooks capture that channel on purpose.
    #
    #   engine = Y::Sync::Engine.new(
    #     load:   ->(key)         { MyStore.load(key) },      # bytes, or nil
    #     change: ->(key, update) { MyStore.append(key, update) }
    #   )
    #
    # The engine decides the ack outcome and owns causal-gap detection and
    # integrated-only serving, through `update_ready?`, `update_advances?`,
    # `handle_sync_message`, and `compacted_state_update`. Transmitting the
    # ack is the transport's job.
    class Engine
      # Frame kinds from Y.message_kind. Its other codes (0 for a drop, 4 for
      # an awareness query) fall through to a no-op.
      MSG_KIND_SYNC_STEP1 = 1
      MSG_KIND_UPDATE = 2
      MSG_KIND_AWARENESS = 3

      # What the transport should do with a handled frame. Each field is
      # separate so a transport routes it without re-inspecting the frame.
      # Route before acking: an ack promises the work already happened.
      #
      # - `reply`     raw protocol bytes for the client that sent this frame
      #               (a SyncStep2 answering a SyncStep1, or a resync
      #               request), or nil.
      # - `broadcast` the caller-supplied encoded frame to relay to the
      #               document's subscribers, or nil. Who receives it is the
      #               transport's policy; the ActionCable adapter broadcasts
      #               to a stream that includes the sender, which is harmless
      #               because applying a CRDT update is idempotent.
      # - `ack`       the reliable-delivery outcome: :recorded (durably
      #               stored, and the caller should relay it), :applied (a
      #               lost-ack retry, relay again but do not re-record),
      #               :gap (rejected, resync requested), or :noop. See
      #               {#ack?}.
      #
      # The branches: a SyncStep1 replies only; a valid update either
      # broadcasts (:recorded, :applied) or replies (:gap); awareness
      # broadcasts only; an unreadable update and any other kind set neither
      # (:noop).
      Result = Data.define(:reply, :broadcast, :ack) do
        # The outcomes a transport should ack: :recorded, whose delta the
        # `change` hook stored, and :applied, an already-present retry the
        # transport relays again. A gap or a no-op is never acked.
        def ack?
          %i[recorded applied].include?(ack)
        end
      end

      # `load`:   called with (key); returns a binary Y.js update to rebuild
      #            the document, or nil for a fresh one.
      # `change`: called with (key, update) to record a delta durably. Runs
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

      # The current integrated state as one gap-free update, for a joiner
      # that applies it directly instead of diffing. `compacted_state_update`
      # excludes pending structs, which a joiner cannot integrate.
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

        doc = load_doc(key)

        # Don't record a causally-incomplete update; request a resync so the
        # gap heals as one complete delta.
        return Result.new(reply: doc.sync_step1, broadcast: nil, ack: :gap) unless doc.update_ready?(update)

        # A lost-ack retry: already recorded, so skip `change`, but do
        # re-relay. If the first attempt died between record and broadcast,
        # this retry is the only path left to the live subscribers. Relaying
        # it twice is safe, since applying a CRDT update is idempotent.
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
