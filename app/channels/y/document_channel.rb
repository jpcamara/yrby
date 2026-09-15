# frozen_string_literal: true

module Y
  # The channel behind collaborative_document_tag. It ships in the gem, so an
  # app subscribes to it by name ("Y::DocumentChannel") with the grant the tag
  # rendered and does not write a channel of its own. Turbo::StreamsChannel
  # plays the same role for turbo_stream_from.
  #
  # The client never names a document. It sends the signed grant the page
  # rendered (record.collaborative_sgid(name)), and the document is whatever
  # that grant verifies to. Your controller authorized the request when it
  # rendered the tag, and the grant is how that decision reaches the socket.
  # An optional authorize_document block can also check the connected user's
  # current permissions when the client subscribes. A missing, tampered,
  # expired, or wrong-attribute grant is rejected, and so is one whose record
  # no longer exists.
  #
  # Storage is whatever the model declared. An attribute marked
  # `has_collaborative_document :name, encrypted: true` loads and appends
  # through Y::EncryptedDocument. A declared storage adapter handles both reads
  # and writes. Undeclared attributes use plain Y::Document. Every change is
  # recorded before it is acknowledged or broadcast. For custom authorization
  # or room-keyed documents, write an application channel instead.
  #
  # The superclass is written as ::ActionCable because inside module Y a bare
  # ActionCable resolves to the gem's own Y::ActionCable concern.
  class DocumentChannel < ::ActionCable::Channel::Base
    include Y::ActionCable

    class_attribute :document_authorizer, instance_accessor: false, default: nil

    # The document key this subscription was authorized for.
    #
    # The policy runs once, at subscribe, and the result has to survive until
    # the next message. Action Cable keeps this channel instance alive, so an
    # instance variable is enough. AnyCable builds a new instance for every
    # command and only carries over declared channel state, so when
    # anycable-rails is loaded the key is declared as state instead. That state
    # is held by anycable-go, not the browser, so a client cannot forge it.
    # Gems load before app/ autoloads, so this check sees anycable-rails
    # whenever the app has it.
    if respond_to?(:state_attr_accessor)
      state_attr_accessor :authorized_document_key
    else
      attr_accessor :authorized_document_key
    end

    # The shipped channel's authorized?, as a block. Configure it in
    # Rails.application.config.to_prepare. It runs in channel context, so
    # current_user and other connection identifiers are available, with the
    # located record and the attribute name. Return truthy to allow access.
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
      # The policy already ran at subscribe, and the subscription is the
      # grant from then on. Running it again on every frame would add a record
      # load and the app's own queries to every keystroke and cursor move. An
      # app that needs to cut off access before the client disconnects should
      # stop the subscription itself. Short grant expiries limit the window.
      #
      # No key means this command did not come through an authorized
      # subscription, so there is nothing to write to.
      key = authorized_document_key
      return reject_document_subscription unless key

      sync_receive(data, key)
    end

    private

    attr_reader :record

    # Nil for a missing, tampered, expired, or wrong-attribute grant, and for a
    # record that has since been destroyed.
    def locate_record
      @record = Y::Collaborative.locate(params[:grant], params[:name])
    end

    # Y::ActionCable calls this from sync_subscribed, before any stream is
    # opened or state is served. The grant already resolved to a record; this
    # runs the application's rule from authorize_document, if there is one.
    def authorized?(_key)
      authorizer = self.class.document_authorizer
      !authorizer || instance_exec(record, params[:name].to_s, &authorizer)
    end

    # Refuse a subscription that was already confirmed. Inside subscribed,
    # reject alone is enough: Action Cable checks the flag afterwards, drops
    # the channel, and tells the client. Later, nothing checks it, so reject
    # alone would leave the streams open and the client unaware. Calling
    # reject_subscription, the framework's own routine, removes this channel
    # from the connection and sends the client the rejection, which the
    # provider treats as "keep the unacked edits and get a fresh grant". Only
    # this subscription goes; others on the same connection keep running.
    def reject_document_subscription
      stop_all_streams
      reject
      reject_subscription
    end

    # Picking storage needs the record, since an attribute may be encrypted or
    # use a custom adapter. It is looked up lazily so a fresh AnyCable instance
    # can handle a document frame, and only document frames need it. Awareness
    # frames are relayed without touching it.
    def document
      (record || locate_record)&.collaborative_document(params[:name].to_s)
    end
  end
end
