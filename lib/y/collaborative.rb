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
      # The signed-GlobalID purpose for one collaborative attribute. A token
      # minted for one attribute only verifies against that attribute's
      # purpose, so it cannot locate a record for any other attribute. The
      # purpose names no channel: any channel that calls locate with the same
      # attribute resolves the record, which is how a custom channel and the
      # shipped one share tokens.
      def sgid_purpose(name) = "yrby/#{name}"

      # Resolves a signed token minted by `collaborative_sgid(name)` back to
      # its record. Returns nil for an invalid, tampered, expired, or
      # wrong-attribute token, and for a record that no longer exists.
      def locate(sgid, name)
        GlobalID::Locator.locate_signed(sgid, for: sgid_purpose(name))
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end

    included do
      class_attribute :collaborative_document_options,
                      instance_accessor: false, default: {}.freeze
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

      # Resolve built-in classes lazily, respecting Rails model load order.
      # A custom store must never silently fall back to plain database reads.
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
  end
end

require "y/collaborative/attribute"
require "y/collaborative/helper"
