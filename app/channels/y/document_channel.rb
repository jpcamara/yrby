# frozen_string_literal: true

module Y
  # The channel behind collaborative_document_tag. It ships with the gem, so an
  # app subscribes to "Y::DocumentChannel" with the grant the tag rendered and
  # doesn't write a channel of its own.
  #
  # The client never picks its own document. It sends the signed grant the
  # page rendered (record.collaborative_sgid(name)), and the channel opens
  # whatever document that grant verifies to. Your controller authorized the
  # request when it rendered the tag, and the grant is how that decision gets
  # to the socket. You can also register an authorize_document block to check
  # the connected user's current permissions when the client subscribes. The
  # channel rejects a missing, tampered, expired, or wrong-attribute grant,
  # and one whose record no longer exists.
  #
  # The model decides where documents are stored. An attribute declared with
  # `has_collaborative_document :name, encrypted: true` loads and appends
  # through Y::EncryptedDocument, and undeclared attributes use plain
  # Y::Document. Each change is recorded before the channel acknowledges or
  # broadcasts it. If you need custom authorization or documents keyed by
  # room, write your own channel.
  #
  # The superclass is written as ::ActionCable because inside module Y a bare
  # ActionCable resolves to the gem's own Y::ActionCable concern.
  class DocumentChannel < ::ActionCable::Channel::Base
    include Y::ActionCable

    class_attribute :document_authorizer, instance_accessor: false, default: nil

    # The document key this subscription was authorized for.
    #
    # The policy runs once, at subscribe, and the key has to be around for the
    # next message. Action Cable keeps the channel instance alive between
    # messages, so an instance variable works there. AnyCable builds a new
    # instance for every command and keeps only declared channel state, so
    # when anycable-rails is loaded we declare the key as state. anycable-go
    # holds that state on the server, where a client can't forge it. Gems load
    # before app/ autoloads, so this check sees anycable-rails whenever the app
    # has it.
    if respond_to?(:state_attr_accessor)
      state_attr_accessor :authorized_document_key
    else
      attr_accessor :authorized_document_key
    end

    # Sets the shipped channel's authorized? check as a block. Configure it in
    # Rails.application.config.to_prepare. The block receives the located
    # record and the attribute name and runs in channel context, so
    # current_user and the other connection identifiers are available. A
    # truthy return allows access.
    def self.authorize_document(&block)
      raise ArgumentError, "authorize_document requires a block" unless block

      self.document_authorizer = block
    end

    on_load { |_key| document.load_state }
    on_change { |_key, update| document.append(update) }

    def subscribed
      return reject unless locate_record

      key = document.key
      self.authorized_document_key = key if sync_subscribed(key)
    rescue StandardError
      reject_document_subscription
      raise
    end

    def receive(data)
      # The policy ran at subscribe, and a confirmed subscription is authorized
      # until it ends. Checking again on every frame would add a record load and
      # the app's own queries to every keystroke and cursor move. An app that
      # needs to cut off access before the client disconnects should stop the
      # subscription itself, and short grant expiries limit the window.
      #
      # Without a key, this command didn't come through an authorized
      # subscription and has no document to write to.
      key = authorized_document_key
      return reject_document_subscription unless key

      sync_receive(data, key)
    end

    private

    attr_reader :record

    # Returns nil for a missing, tampered, expired, or wrong-attribute grant,
    # and for a record that has since been destroyed.
    def locate_record
      @record = Y::Collaborative.locate(params[:grant], params[:name])
    end

    # Y::ActionCable calls this from sync_subscribed before it opens a stream or
    # serves any state, and by then the grant has resolved to a record. It runs
    # the app's authorize_document block if one is set.
    def authorized?(_key)
      authorizer = self.class.document_authorizer
      !authorizer || instance_exec(record, params[:name].to_s, &authorizer)
    end

    # Refuses a subscription that was already confirmed. Inside subscribed,
    # calling reject is enough, because Action Cable checks the flag afterwards,
    # drops the channel, and tells the client. Later on nothing checks the
    # flag, so reject by itself would leave the streams open and the client
    # unaware. reject_subscription is the framework's routine for this case. It
    # removes the channel from the connection and sends the client the
    # rejection, which the provider treats as "keep the unacked edits and get a
    # fresh grant". It closes this subscription only, and others on the same
    # connection keep running.
    def reject_document_subscription
      stop_all_streams
      reject
      reject_subscription
    end

    # Choosing storage needs the record, because an attribute may be
    # encrypted. The record loads lazily so a fresh AnyCable instance can
    # handle a document frame. Awareness frames are relayed without it, so
    # only document frames load it.
    def document
      (record || locate_record)&.collaborative_document(params[:name].to_s)
    end
  end
end
