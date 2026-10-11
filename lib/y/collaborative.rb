# frozen_string_literal: true

require "active_support/concern"
require "global_id"
require "y/action_cable"

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
  #   # Not memoized, because AnyCable gives each command a fresh channel
  #   # instance and a cached record would go stale. Y::DocumentChannel
  #   # does the same.
  #   def record
  #     Y::Collaborative.locate(params[:grant], :body)
  #   end
  #
  # The engine includes this into ActiveRecord::Base so any channel's
  # authorized? can use it. lexxy-realtime uses the same token flow.
  module Collaborative
    extend ActiveSupport::Concern

    class << self
      # The signed-GlobalID purpose for one collaborative attribute. A token
      # signed for one attribute verifies only against that attribute's
      # purpose, so it can't locate the record through any other attribute.
      # The purpose leaves out the channel name, so a custom channel and the
      # shipped one can both resolve the same tokens for an attribute.
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
      # Declares how one attribute's document is stored. The shipped channel
      # and Ruby reads both follow it, and undeclared attributes use plain
      # Y::Document.
      def has_collaborative_document(name, encrypted: false) # rubocop:disable Naming/PredicatePrefix
        self.collaborative_document_options = collaborative_document_options.merge(
          name.to_s => { encrypted: encrypted }.freeze
        ).freeze
      end

      # Returns the model that stores this attribute's document,
      # Y::EncryptedDocument for an attribute declared encrypted and
      # Y::Document for the rest. It resolves the constant on every call so
      # that declaring an attribute doesn't load the engine's models while the
      # app's models are still loading.
      def collaborative_document_class(name)
        encrypted = collaborative_document_options.dig(name.to_s, :encrypted)
        encrypted ? Y::EncryptedDocument : Y::Document
      end
    end

    # Returns the document for one attribute, stored the way the model
    # declared. It responds to load_state, append, y_doc, and key.
    def collaborative_document(name)
      Attribute.new(self, name)
    end

    # A signed token that a channel can pass to Y::Collaborative.locate to get
    # this record back, for this attribute only. Pass expires_in: to limit how
    # long the grant lasts. Without it GlobalID's own default applies, which is
    # one month under Rails. We pass the option through only when it's given,
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
