# frozen_string_literal: true

require "base64"
require "json"

module Y::ActionCable # rubocop:disable Style/ClassAndModuleChildren
  # A Ruby process that follows a document live. It holds a Y::Doc, applies
  # every update the document's subscribers broadcast, and tells you when
  # something changed. That is how an agent reacts to people's edits as they
  # happen, rather than only when it next reads the store.
  #
  #   peer = Y::ActionCable::Peer.new(key)
  #   peer.on_update { |update, doc| ... }   # each update that advanced the doc
  #   peer.subscribe
  #   peer.doc.apply_update(store.replay(key)) # then load: an edit that lands
  #                                            # in between is applied, not lost
  #
  # Callbacks run on the cable adapter's thread. Keep them short, or hand the
  # work to your own thread. Updates the doc already holds, including the
  # ones this process broadcast itself, do not fire on_update, so an agent
  # writing through the same doc does not react to its own edits.
  class Peer
    attr_reader :key, :doc

    def initialize(key, doc: Y::Doc.new)
      @key = key.to_s
      @doc = doc
      @on_update = nil
      @on_awareness = nil
      @active = false
      @callback = method(:receive)
    end

    def on_update(&block)
      @on_update = block
      self
    end

    def on_awareness(&block)
      @on_awareness = block
      self
    end

    # Subscribe and wait, up to `timeout` seconds, for the adapter to confirm
    # the subscription, so an update broadcast right after this call is not
    # missed. Adapters register subscriptions asynchronously.
    def subscribe(timeout: 5)
      confirmed = Queue.new
      @active = true
      ::ActionCable.server.pubsub.subscribe(Sync.stream_name(@key), @callback, -> { confirmed << true })
      confirmed.pop(timeout: timeout)
      self
    end

    # Stop following. Anything the adapter still delivers is dropped.
    def unsubscribe
      @active = false
      ::ActionCable.server.pubsub.unsubscribe(Sync.stream_name(@key), @callback)
      self
    end

    private

    # One pubsub message: the JSON envelope a channel or broadcast sent. A
    # frame that is not a well-formed message is ignored; nothing here may
    # raise into the adapter's listener.
    def receive(message)
      return unless @active

      frame = decode(message) or return
      case Y.message_kind(frame)
      when Sync::MSG_KIND_UPDATE
        update = Y.update_from_message(frame)
        return unless update && @doc.update_advances?(update)

        @doc.apply_update(update)
        @on_update&.call(update, @doc)
      when Sync::MSG_KIND_AWARENESS
        @on_awareness&.call(frame)
      end
    rescue StandardError => e
      ::ActionCable.server.logger&.warn("Y::ActionCable::Peer #{@key}: #{e.class}: #{e.message}")
    end

    def decode(message)
      encoded = JSON.parse(message.to_s)["update"]
      return unless encoded.is_a?(String)

      Base64.strict_decode64(encoded)
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end
  end
end
