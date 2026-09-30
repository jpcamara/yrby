# frozen_string_literal: true

require "active_support/concern"
require "global_id"

module Y
  # The signed token that connects a page to a channel for record-backed
  # collaborative documents.
  #
  # The client never picks its own document. The server signs a token for the
  # record and attribute, the page renders it, and the channel looks the
  # record up from it. The token is a signed GlobalID scoped to one attribute.
  #
  #   # the view
  #   tag.div data: { grant: post.collaborative_sgid(:body) }
  #
  #   # the channel
  #   def authorized?(_key)
  #     record.present? && record.editable_by?(current_user)
  #   end
  #
  #   # Not memoized. Under AnyCable each command gets a fresh channel
  #   # instance, so a cached record would go stale. Y::DocumentChannel
  #   # does the same.
  #   def record
  #     Y::Collaborative.locate(params[:grant], :body)
  #   end
  #
  # The engine includes this into ActiveRecord::Base. lexxy-realtime uses the
  # same token flow. yrby-rails provides it so any channel's authorized? can
  # use it.
  module Collaborative
    extend ActiveSupport::Concern

    class << self
      # The signed-GlobalID purpose for one collaborative attribute. A token
      # signed for one attribute only verifies against that attribute's
      # purpose, so it won't locate the record through any other attribute.
      # The purpose doesn't include a channel name, so a custom channel and
      # the shipped one can both resolve the same tokens for an attribute.
      def sgid_purpose(name) = "yrby/#{name}"

      # Looks up the record for a token from `collaborative_sgid(name)`.
      # Returns nil for an invalid, tampered, expired, or wrong-attribute
      # token, and for a record that no longer exists.
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
      # Declares how one attribute's document is stored, for both the shipped
      # channel and Ruby reads. Undeclared attributes use plain Y::Document.
      def has_collaborative_document(name, encrypted: false) # rubocop:disable Naming/PredicatePrefix
        self.collaborative_document_options = collaborative_document_options.merge(
          name.to_s => { encrypted: encrypted }.freeze
        ).freeze
      end

      # The model that stores this attribute's document. Y::EncryptedDocument
      # when the attribute was declared encrypted, Y::Document otherwise. It
      # is looked up on each call, so declaring the attribute doesn't load the
      # engine's models while the app's are still loading.
      def collaborative_document_class(name)
        encrypted = collaborative_document_options.dig(name.to_s, :encrypted)
        encrypted ? Y::EncryptedDocument : Y::Document
      end
    end

    # The document for one attribute, using the storage the model declared.
    # It has load_state, append, y_doc, and key.
    def collaborative_document(name)
      Attribute.new(self, name)
    end

    # A signed token a channel can pass to Y::Collaborative.locate to get this
    # record back, for this attribute only. Pass expires_in: to limit how long
    # the grant lasts. Without it, GlobalID's own default applies, which is
    # one month under Rails. The option is only passed through when given,
    # because an explicit nil would mean "never expire".
    def collaborative_sgid(name, expires_in: nil)
      options = { for: Y::Collaborative.sgid_purpose(name) }
      options[:expires_in] = expires_in if expires_in
      to_sgid(**options).to_s
    end
  end
end

require "y/collaborative/attribute"
require "y/collaborative/helper"
