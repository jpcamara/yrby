# frozen_string_literal: true

require "base64"
require "json"
require "y/action_cable/sync"
require "y/action_cable/client/outbox"

module Y::ActionCable # rubocop:disable Style/ClassAndModuleChildren
  class Client
    # The client side of the protocol with no socket: cable messages in,
    # cable messages out through the block, and the document kept current.
    # It is what the JS provider's session is, in Ruby, so it can be driven
    # in a test with nothing listening. The client feeds it every message
    # the socket delivers and every command the caller makes, all on one
    # reactor, so it keeps no locks.
    #
    # Messages are the JSON hashes the cable carries. A command goes out as
    # { command:, identifier:, data: } and a channel message comes in as
    # { identifier:, message: }, the message being Sync's envelope.
    class Session
      # The second byte of a sync frame is y-protocols' sync type; 1 is
      # SyncStep2, the server's answer to our SyncStep1.
      SYNC_STEP2 = 1

      attr_reader :doc, :identifier

      # `root:` names the root XmlText whose top-level blocks on_update
      # reports as changed; nil turns block tracking off.
      def initialize(doc, identifier, root: "root", &transmit)
        @doc = doc
        @identifier = identifier
        @root = root
        @transmit = transmit
        @outbox = Outbox.new
        @subscribed = false
        @synced = false
        @loaded = false
        @presence = nil
        @asked = nil
        @on_update = nil
        @on_awareness = nil
      end

      def on_update(&block) = @on_update = block
      def on_awareness(&block) = @on_awareness = block
      def synced? = @synced
      def pending? = @outbox.pending?

      # One message from the server. Returns what it was, for the connection
      # to act on: :welcome, :ping, :confirmed, :rejected, :disconnect,
      # :synced for the message that completed a handshake, :message for any
      # other message of this subscription, and nil for anything else.
      def receive(message)
        case message["type"]
        when "welcome" then welcome
        when "ping" then :ping
        when "confirm_subscription" then confirmed if mine?(message)
        when "reject_subscription" then :rejected if mine?(message)
        when "disconnect" then :disconnect
        else
          payload = message["message"]
          receive_payload(payload) || :message if mine?(message) && payload.is_a?(Hash)
        end
      end

      # The socket dropped. Pending updates stay for the next confirmation.
      def dropped
        @subscribed = false
        @synced = false
      end

      # A local update: kept until the server acks it, sent now when
      # subscribed and otherwise when the subscription is next confirmed.
      def send_update(update)
        entry = @outbox.push(update)
        send_entry(entry) if @subscribed
      end

      # Presence goes out as is. The last frame is said again on a reconnect,
      # so peers see this client back without waiting for its next refresh.
      def send_awareness(frame)
        @presence = frame
        send_frame(frame) if @subscribed
      end

      # Send everything unacked, in order. The retransmit timer calls this.
      def resend
        return unless @subscribed

        @outbox.pending.each { |entry| send_entry(entry) }
      end

      def unsubscribe
        command("unsubscribe") if @subscribed
        @subscribed = false
      end

      private

      # The server says welcome once the socket is up, and takes commands
      # from then on.
      def welcome
        command("subscribe")
        :welcome
      end

      # The subscription is confirmed: answer the server's opening SyncStep1
      # if it came first, send ours, say who we are, and replay what is
      # still unacked. The server's SyncStep2 completes the handshake.
      def confirmed
        @subscribed = true
        send_frame(@doc.handle_sync_message(@asked)[2]) if @asked
        @asked = nil
        send_frame(@doc.sync_step1)
        send_frame(@presence) if @presence
        resend
        :confirmed
      end

      def receive_payload(payload)
        return @outbox.ack(payload["ack"]) && :ack if payload.key?("ack")

        # AnyCable whispers presence under its own key; the server relays
        # document frames under "update".
        encoded = payload["awareness"] || payload["update"]
        return unless encoded.is_a?(String)

        frame = Base64.strict_decode64(encoded)
        receive_frame(frame)
      rescue ArgumentError
        nil
      end

      # A malformed frame is dropped by Y.message_kind. The server's SyncStep1
      # is answered with our full state, the way a browser answers it; one
      # that arrives before the subscription is confirmed (Action Cable sends
      # it from `subscribed`) waits for the confirmation.
      def receive_frame(frame)
        case Y.message_kind(frame)
        when Sync::MSG_KIND_SYNC_STEP1
          @subscribed ? send_frame(@doc.handle_sync_message(frame)[2]) : @asked = frame
          nil
        when Sync::MSG_KIND_UPDATE then receive_update(frame)
        when Sync::MSG_KIND_AWARENESS
          @on_awareness&.call(frame)
          :awareness
        end
      end

      # Apply what the doc does not already hold (its own updates come back
      # from the server too) and report it. The first SyncStep2 is the load,
      # not a change, so it does not fire on_update; a later one, after a
      # reconnect, carries what was missed and does.
      def receive_update(frame)
        update = Y.update_from_message(frame)
        apply(update) if update && @doc.update_advances?(update)
        return :update unless frame.getbyte(1) == SYNC_STEP2 && !@synced

        @synced = true
        @loaded = true
        :synced
      end

      def apply(update)
        changed = @root ? @doc.apply_update_changes(update, @root) : (@doc.apply_update(update) && nil)
        @on_update&.call(update, @doc, changed) if @loaded
      end

      def send_entry(entry)
        message("update" => Base64.strict_encode64(Y.wrap_update(entry.update)), "id" => entry.id)
      end

      def send_frame(bytes) = message("update" => Base64.strict_encode64(bytes))

      def message(data)
        @transmit.call("command" => "message", "identifier" => @identifier, "data" => JSON.generate(data))
      end

      def command(name) = @transmit.call("command" => name, "identifier" => @identifier)

      def mine?(message) = message["identifier"] == @identifier
    end
  end
end
