# frozen_string_literal: true

require "active_support/concern"
require "global_id"

module Y
  # The signed handshake between a page and a channel for record-backed
  # collaborative documents.
  #
  # A client should never name its document; the server names it, signs the
  # claim, and the channel trades the token back for the record. The token is
  # a signed GlobalID scoped to one attribute: mint it where the page renders,
  # resolve it where the channel authorizes.
  #
  #   # the view
  #   tag.div data: { sgid: post.collaborative_sgid(:body) }
  #
  #   # the channel
  #   def authorized?(_key)
  #     record.present? && record.editable_by?(current_user)
  #   end
  #
  #   def record
  #     @record ||= Y::Collaborative.locate(params[:sgid], :body)
  #   end
  #
  # The engine includes this into ActiveRecord::Base. This is the token flow
  # lexxy-realtime uses, provided by yrby-rails itself so any channel's
  # authorized? can lean on it.
  module Collaborative
    extend ActiveSupport::Concern

    class << self
      # The signed-GlobalID purpose for one collaborative attribute. This
      # string is the public contract: a token minted for one attribute
      # verifies only against that attribute's purpose, so it cannot locate
      # a record for any other attribute or channel.
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
      # Per-attribute storage declarations, class name => resolved lazily so
      # declaring a model never forces the engine's models to load first.
      class_attribute :collaborative_document_classes,
                      instance_accessor: false, default: {}.freeze
    end

    class_methods do
      # Declares which storage class backs one collaborative attribute.
      # Encryption is a property of the attribute's storage, so it is
      # declared here on the model — never by the page or the client:
      #
      #   has_collaborative_document :body, encrypted: true
      #
      # Y::DocumentChannel consults this declaration and routes every load
      # and append for the attribute through Y::EncryptedDocument, which
      # stores state and update payloads under Active Record encryption.
      # Undeclared attributes keep plain Y::Document storage.
      def has_collaborative_document(name, encrypted: false) # rubocop:disable Naming/PredicatePrefix
        self.collaborative_document_classes = collaborative_document_classes.merge(
          name.to_sym => (encrypted ? "Y::EncryptedDocument" : "Y::Document")
        ).freeze
      end

      # The storage class for one attribute — the declared one, or plain
      # Y::Document. Everything server-side must go through this one class
      # per attribute: rows written encrypted read back as ciphertext
      # through the plain classes.
      def collaborative_document_class(name)
        (collaborative_document_classes[name.to_sym] || "Y::Document").constantize
      end
    end

    # A signed token a channel can trade back for this record with
    # Y::Collaborative.locate — but only for this attribute.
    def collaborative_sgid(name)
      to_sgid(for: Y::Collaborative.sgid_purpose(name)).to_s
    end
  end
end

require "y/collaborative/helper"
