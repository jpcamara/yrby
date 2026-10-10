# frozen_string_literal: true

require "active_support/concern"
require "global_id"

module Y
  # The signed token that connects a page to a channel for record-backed
  # collaborative documents.
  #
  # The client never names its document. The server names it, signs the name,
  # and the channel trades the token back for the record. The token is a
  # signed GlobalID scoped to one attribute. The page mints it and the channel
  # resolves it.
  #
  #   # the view
  #   tag.div data: { grant: post.collaborative_sgid(:body) }
  #
  #   # the channel
  #   def authorized?(_key)
  #     record.present? && record.editable_by?(current_user)
  #   end
  #
  #   # Not memoized: under AnyCable each command gets a fresh channel
  #   # instance, and a cached record would go stale. Y::DocumentChannel
  #   # resolves the grant the same way.
  #   def record
  #     Y::Collaborative.locate(params[:grant], :body)
  #   end
  #
  # The engine includes this into ActiveRecord::Base. lexxy-realtime uses the
  # same token flow, and yrby-rails provides it so any channel's authorized?
  # can use it.
  module Collaborative
    extend ActiveSupport::Concern

    class << self
      # The secret that signs and verifies JWT grants (Y::Collaborative::Grant),
      # shared with any other app (a Loco app, say) whose grants this one
      # accepts. Set config.yrby.grant_secret. Without it, only signed
      # GlobalIDs are grants.
      attr_accessor :grant_secret

      # What collaborative_document_tag renders: :sgid (the default), or
      # :jwt for grants another app can verify. Set config.yrby.grant_format.
      attr_writer :grant_format

      def grant_format = @grant_format || :sgid

      # The signed-GlobalID purpose for one collaborative attribute. A token
      # minted for one attribute only verifies against that attribute's
      # purpose, so it cannot locate a record for any other attribute. The
      # purpose names no channel: any channel that calls locate with the same
      # attribute resolves the record, which is how a custom channel and the
      # shipped one share tokens.
      def sgid_purpose(name) = "yrby/#{name}"

      # Resolves a grant back to its record: a signed GlobalID from
      # `collaborative_sgid(name)`, or a JWT grant from `collaborative_grant(name)`
      # or another app sharing grant_secret. Returns nil for an invalid,
      # tampered, expired, or wrong-attribute grant, and for a record that no
      # longer exists.
      def locate(grant, name)
        return locate_jwt(grant, name) if Grant.jwt?(grant)

        GlobalID::Locator.locate_signed(grant, for: sgid_purpose(name))
      rescue ActiveRecord::RecordNotFound
        nil
      end

      private

      # A JWT grant names its record as "<polymorphic name>/<public id>". The
      # class must be a model that includes Y::Collaborative: the grant was
      # signed with our secret, but it only ever opens collaborative records.
      def locate_jwt(grant, name)
        subject = Grant.verify(grant, name: name, secret: grant_secret)
        record_type, _, public_id = subject&.rpartition("/")
        return nil if record_type.nil? || record_type.empty? || public_id.empty?

        model = record_type.safe_constantize
        return nil unless model.is_a?(Class) && model < ActiveRecord::Base && model.include?(Y::Collaborative)

        model.find_by(model.collaborative_public_id => public_id)
      end
    end

    included do
      class_attribute :collaborative_document_options,
                      instance_accessor: false, default: {}.freeze
      # The column JWT grants name records by: the primary key unless the
      # model has a public id of its own, as Loco models have pid.
      #
      #   self.collaborative_public_id = :pid
      class_attribute :collaborative_public_id, instance_accessor: false, default: :id
    end

    class_methods do
      # Select storage once for both the shipped channel and Ruby reads.
      # A custom adapter implements load(record, name) and write(record, name, update).
      # Undeclared attributes use plain Y::Document storage.
      def has_collaborative_document(name, encrypted: false, storage: nil) # rubocop:disable Naming/PredicatePrefix
        if storage && (!storage.respond_to?(:load) || !storage.respond_to?(:write))
          raise ArgumentError, "storage must implement load(record, name) and write(record, name, update)"
        end
        raise ArgumentError, "encrypted: applies to built-in storage only" if encrypted && storage

        self.collaborative_document_options = collaborative_document_options.merge(
          name.to_s => { encrypted: encrypted, storage: storage }.freeze
        ).freeze
      end

      # The model that stores this attribute's document: Y::Document, or
      # Y::EncryptedDocument when declared encrypted. An undeclared attribute
      # gets the plain model. Looked up on each call rather than stored at
      # declaration, so the engine's models are not loaded while the app's
      # are still loading. A custom store keeps the document elsewhere and
      # has no model, so asking for one is an error: returning Y::Document
      # would quietly read an empty row while the store held the real one.
      def collaborative_document_class(name)
        options = collaborative_document_options.fetch(name.to_s, {})
        if options[:storage]
          raise ArgumentError,
                "custom storage has no document model; use collaborative_document(name)"
        end

        options[:encrypted] ? Y::EncryptedDocument : Y::Document
      end
    end

    # The document for one attribute: load_state, append, and doc, using the
    # storage the model declared.
    def collaborative_document(name)
      Attribute.new(self, name)
    end

    # A signed token a channel can trade back for this record with
    # Y::Collaborative.locate, but only for this attribute.
    # Pass expires_in: to bound the grant's life. Without it, GlobalID's own
    # default applies, which is one month under Rails. The key is only passed
    # through when given: an explicit nil would mean "never expire".
    def collaborative_sgid(name, expires_in: nil)
      options = { for: Y::Collaborative.sgid_purpose(name) }
      options[:expires_in] = expires_in if expires_in
      to_sgid(**options).to_s
    end

    # The same permission as collaborative_sgid, as a JWT that any app with
    # the shared grant_secret verifies, a Loco app included. A JWT grant must
    # expire: without expires_in: it lasts as long as a signed GlobalID would
    # (SignedGlobalID.expires_in, a month under Rails).
    def collaborative_grant(name, expires_in: nil)
      secret = Y::Collaborative.grant_secret or raise ArgumentError, "set config.yrby.grant_secret to mint JWT grants"
      lifetime = expires_in || SignedGlobalID.expires_in || 1.month
      public_id = public_send(self.class.collaborative_public_id)
      Grant.encode(subject: "#{self.class.polymorphic_name}/#{public_id}", name: name,
                   expires_at: Time.now + lifetime, secret: secret)
    end
  end
end

require "y/collaborative/attribute"
require "y/collaborative/grant"
require "y/collaborative/helper"
