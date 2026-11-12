# frozen_string_literal: true

require "active_support/concern"
require "active_support/deprecation"
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
  #   tag.div data: { grant: post.collaborative_document(:body).grant }
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
  # Warns about yrby-rails methods that are going away. The engine adds it to
  # Rails.application.deprecators, so the app's deprecation settings apply.
  def self.deprecator = @deprecator ||= ActiveSupport::Deprecation.new("0.9", "yrby-rails")

  module Collaborative
    extend ActiveSupport::Concern

    class << self
      # The signed-GlobalID purpose for one collaborative attribute. A token
      # signed for one attribute verifies only against that attribute's
      # purpose, so it can't locate the record through any other attribute.
      # The purpose leaves out the channel name, so a custom channel and the
      # shipped one can both resolve the same tokens for an attribute.
      def sgid_purpose(name) = "yrby/#{name}"

      # Looks up the record for a grant from `collaborative_document(name).grant`.
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
      # Declares how one attribute's document is stored, and the channel that
      # serves it: an app's own Y::DocumentChannel subclass, by name. The
      # shipped channel and Ruby reads both follow it. Undeclared attributes
      # use plain Y::Document and Y::DocumentChannel.
      #
      # store: :pg_yrby keeps the document in a ydoc column and does the
      # merging, compaction and sync in Postgres with the pg_yrby extension
      # (Y::PgDocument). It can't be combined with encrypted:, because the
      # database has to read the document.
      def has_collaborative_document(name, encrypted: false, channel: nil, store: nil) # rubocop:disable Naming/PredicatePrefix
        unless [nil, :pg_yrby].include?(store)
          raise ArgumentError, "unknown collaborative document store #{store.inspect}"
        end
        raise ArgumentError, "store: :pg_yrby can't be encrypted" if store && encrypted

        self.collaborative_document_options = collaborative_document_options.merge(
          name.to_s => { encrypted: encrypted, channel: channel&.to_s, store: store }.freeze
        ).freeze
      end

      # Returns the model that stores this attribute's document:
      # Y::EncryptedDocument for an attribute declared encrypted,
      # Y::PgDocument for store: :pg_yrby, and Y::Document for the rest. It
      # resolves the constant on every call so that declaring an attribute
      # doesn't load the engine's models while the app's models are still
      # loading.
      def collaborative_document_class(name)
        options = collaborative_document_options.fetch(name.to_s, {})
        return Y::EncryptedDocument if options[:encrypted]
        return Y::PgDocument if options[:store] == :pg_yrby

        Y::Document
      end
    end

    # Returns the document for one attribute, stored the way the model
    # declared. It responds to load_state, append, edit, y_doc, key, grant,
    # and channel.
    def collaborative_document(name)
      Attribute.new(self, name)
    end

    # Deprecated. Use collaborative_document(name).grant. This one always
    # signs yrby's own grant, as it did before.
    def collaborative_sgid(name, expires_in: nil)
      Y.deprecator.warn("collaborative_sgid(name) is deprecated. Use collaborative_document(name).grant instead.")
      Attribute.new(self, name).grant(expires_in:)
    end
  end
end

require "y/collaborative/attribute"
require "y/collaborative/helper"
