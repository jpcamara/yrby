# frozen_string_literal: true

module Y
  # The gem-shipped channel behind collaborative_document_tag: the whole wire
  # side of a record-backed collaborative document, the way Turbo::StreamsChannel
  # is the whole wire side of a turbo_stream_from subscription. Apps subscribe
  # to it by name ("Y::DocumentChannel") with the grant the tag rendered; there
  # is no channel to generate or write.
  #
  # The client never names a document. It presents the signed, attribute-scoped
  # grant minted where the page rendered (record.collaborative_sgid(name)), and
  # the document is whatever that grant verifies to. Authorization happened
  # when your controller decided to render the tag; the grant carries that
  # decision to the socket. An optional authorize_document block also checks
  # the connected user's current permissions before subscribing or processing
  # any incoming message. A missing, tampered, expired, or wrong-attribute
  # grant (or one whose record no longer exists) is rejected.
  #
  # Storage follows the record's declaration: an attribute the model marked
  # `has_collaborative_document :name, encrypted: true` routes every load and
  # append through Y::EncryptedDocument; undeclared attributes use plain
  # Y::Document. A declared storage adapter supplies both reads and writes.
  # Every change is recorded before it is acknowledged or broadcast. Custom
  # authorization or room-keyed documents can use an application channel.
  # ::ActionCable, explicitly: inside module Y a bare ActionCable resolves
  # to the gem's own Y::ActionCable concern.
  class DocumentChannel < ::ActionCable::Channel::Base
    include Y::ActionCable

    class_attribute :document_authorizer, instance_accessor: false, default: nil

    # Configure in Rails.application.config.to_prepare. Runs in channel context
    # (including connection identifiers such as current_user), with a freshly
    # located record and the attribute name. Return truthy to allow access.
    def self.authorize_document(&block)
      raise ArgumentError, "authorize_document requires a block" unless block

      self.document_authorizer = block
    end

    on_load { |_key| document.load_state }
    on_change { |_key, update| document.append(update) }

    def subscribed
      return reject unless document_authorized?

      sync_subscribed(document.key)
    rescue StandardError
      reject_document_subscription
      raise
    end

    def receive(data)
      return unless authorize_receive

      sync_receive(data, document.key)
    end

    private

    def authorized?(_key) = record.present?

    attr_reader :record

    def document_authorized?
      # Do not retain permission-relevant attributes or associations between
      # messages, even when Action Cable keeps this channel instance alive.
      @record = Y::Collaborative.locate(params[:grant], params[:name])
      return false unless record

      authorizer = self.class.document_authorizer
      !authorizer || instance_exec(record, params[:name].to_s, &authorizer)
    end

    def authorize_receive
      return true if document_authorized?

      reject_document_subscription
      false
    rescue StandardError
      reject_document_subscription
      raise
    end

    def reject_document_subscription
      stop_all_streams
      reject
      # Action Cable's reject only marks a channel; after subscription it does
      # not remove it or notify the client. Use the framework's rejection path
      # so the provider retains unacknowledged work and other channels stay up.
      reject_subscription
    end

    def document
      record&.collaborative_document(params[:name].to_s)
    end
  end
end
