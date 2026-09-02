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

    # A signed token a channel can trade back for this record with
    # Y::Collaborative.locate — but only for this attribute.
    def collaborative_sgid(name)
      to_sgid(for: Y::Collaborative.sgid_purpose(name)).to_s
    end
  end
end

require "y/collaborative/helper"
