# frozen_string_literal: true

require "json"
require "rack"
require "anycable"
require "y/action_cable"

module Y
  # yrby behind anycable-go without Rails. anycable-go holds the WebSockets
  # and calls the app over AnyCable's RPC for each connect, subscribe, and
  # message. A subclass of Y::AnyCable::Channel gets the same API as
  # Y::ActionCable: on_load, on_change, authorized?, sync_subscribed, and
  # sync_receive.
  #
  #   class DocumentChannel < Y::AnyCable::Channel
  #     def subscribed = sync_subscribed(params[:id])
  #     def receive(data) = sync_receive(data, params[:id])
  #
  #     private
  #
  #     def authorized?(key) = Membership.exists?(user_id: identifiers["user_id"], key:)
  #   end
  #
  #   AnyCable.connection_factory = Y::AnyCable::Connection
  #
  # Every RPC call builds a fresh channel from the subscription identifier, so
  # nothing set in subscribed survives to receive. Pass the key to
  # sync_receive each time. anycable-go only forwards messages for
  # subscriptions it confirmed, so the identifier's params are trusted.
  #
  # Requiring this file also loads Y::Document and Y::DocumentUpdate, the
  # storage the hooks default to.
  module AnyCable
    # Sends an update to everyone subscribed to a document, from outside a
    # channel. Record the update first. This only distributes it.
    def self.broadcast(key, update)
      encoded = Base64.strict_encode64(Y.wrap_update(update))
      ::AnyCable.broadcast(Y::ActionCable.stream_name(key), { "update" => encoded }.to_json)
    end

    # The parts of Action Cable's channel API that Y::ActionCable::Sync uses,
    # on top of an AnyCable socket.
    class Channel
      include Y::ActionCable::Sync

      # The channel class an identifier names. Only subclasses qualify.
      def self.find(name)
        return unless name.is_a?(String) && name.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)

        klass = Object.const_get(name)
        klass if klass.is_a?(Class) && klass < self
      rescue NameError
        nil
      end

      attr_reader :identifier, :params

      def initialize(socket, identifier, identifiers)
        @socket = socket
        @identifier = identifier
        @identifiers = identifiers
        @params = JSON.parse(identifier).except("channel").transform_keys(&:to_sym)
      end

      def subscribed; end
      def receive(_data); end
      def unsubscribed; end

      def rejected? = @rejected == true

      # Public because Sync checks respond_to?(:whispers_to) before it opens
      # the awareness stream with whispers on. Clients can then send presence
      # straight to each other through anycable-go, with no RPC.
      def whispers_to(stream) = @socket.whisper(identifier, stream)

      private

      # What the connection was identified with: the hash Connection#identify
      # returned, or the identifiers in an anycable-go JWT. String keys.
      attr_reader :identifiers

      def reject = (@rejected = true)

      def stream_from(stream, whisper: false)
        @socket.subscribe(identifier, stream)
        whispers_to(stream) if whisper
      end

      def transmit(data)
        @socket.transmit({ "identifier" => identifier, "message" => data }.to_json)
      end

      def logger = ::AnyCable.logger

      def sync_broadcast(stream, message) = ::AnyCable.broadcast(stream, message.to_json)
    end

    # The connection factory. Subclass it and define identify to authenticate:
    #
    #   class CableConnection < Y::AnyCable::Connection
    #     def identify(request)
    #       user = User.find_by_session(request.cookies["session"])
    #       { "user_id" => user.id } if user
    #     end
    #   end
    #
    #   AnyCable.connection_factory = CableConnection
    #
    # When anycable-go verifies a JWT itself (--jwt_secret), it skips the
    # connect call and sends the token's identifiers with each command, so
    # identify doesn't run and channels see the same identifiers.
    #
    # handle_open, handle_close, and handle_channel_command are the calls
    # anycable-core makes. The command handlers return whether the RPC
    # succeeded.
    class Connection
      # rubocop:disable Naming/PredicateMethod
      def self.call(socket, identifiers: nil, subscriptions: nil)
        new(socket, identifiers, subscriptions)
      end

      def initialize(socket, identifiers_json = nil, subscriptions = nil)
        @socket = socket
        @identifiers = identifiers_json.to_s.empty? ? {} : JSON.parse(identifiers_json)
        @subscriptions = subscriptions || []
      end

      # Returns the identifiers for this connection, a hash, or nil to refuse
      # it. request is a Rack::Request for the WebSocket upgrade. Accepts every
      # connection by default. Channels still check authorized?(key).
      def identify(_request) = {}

      def handle_open
        identifiers = identify(Rack::Request.new(@socket.env))
        unless identifiers
          @socket.transmit({ "type" => "disconnect", "reason" => "unauthorized", "reconnect" => false }.to_json)
          @socket.close
          return
        end

        @identifiers = identifiers.transform_keys(&:to_s)
        @socket.transmit({ "type" => "welcome" }.to_json)
      end

      def handle_close
        @subscriptions.each { |identifier| channel_for(identifier)&.unsubscribed }
        true
      end

      def identifiers_json = @identifiers.to_json

      # Clients reach only subscribed, unsubscribed, and receive. A message
      # naming any other action is refused, so a channel's helpers (and Sync's
      # methods) can't be called from a client.
      def handle_channel_command(identifier, command, data)
        channel = channel_for(identifier) or return false

        case command
        when "subscribe" then subscribe(channel)
        when "unsubscribe" then unsubscribe(channel)
        when "message" then perform(channel, data)
        else false
        end
      end

      private

      def channel_for(identifier)
        klass = Channel.find(JSON.parse(identifier)["channel"])
        klass&.new(@socket, identifier, @identifiers)
      end

      def subscribe(channel)
        channel.subscribed
        type = channel.rejected? ? "reject_subscription" : "confirm_subscription"
        @socket.transmit({ "identifier" => channel.identifier, "type" => type }.to_json)
        !channel.rejected?
      end

      def unsubscribe(channel)
        channel.unsubscribed
        @socket.unsubscribe_from_all(channel.identifier)
        true
      end

      def perform(channel, data)
        payload = JSON.parse(data)
        return false unless payload.is_a?(Hash)

        action = payload.delete("action")
        return false unless action.nil? || action == "receive"

        channel.receive(payload)
        true
      end
      # rubocop:enable Naming/PredicateMethod
    end
  end
end

# Under Rails the engine autoloads the models.
unless defined?(Yrby::Engine)
  require "active_record"
  require_relative "../../app/models/y/document_update"
  require_relative "../../app/models/y/document"
end
