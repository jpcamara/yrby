# frozen_string_literal: true

require "y"

module Y
  # Collaborative form fields over yrby: a model macro
  # (has_collaborative_fields), form helpers that render <yrby-document> and
  # <collaborative-field>, and the channel that serves them. One document per
  # record, named "fields", holds the whole field set: LWW fields in a
  # "fields" map share, and each text-tier field in its own "fields/<name>"
  # text share.
  module Forms
    # The collaborative document every field set lives in, one per record.
    DOCUMENT_NAME = "fields"

    # The channel has_collaborative_fields declares for that document.
    CHANNEL_NAME = "Y::Forms::FieldsChannel"

    class << self
      # Presence identity, called with the view context; returns { name:, color: }
      # (a nil color gets a stable one derived from the name).
      attr_writer :identity

      def identity
        @identity ||= lambda do |view|
          user = view.respond_to?(:current_user) ? view.current_user : nil
          # Use Anonymous when no display name is available.
          name = user && %i[name username handle].lazy.filter_map { |a| user.try(a).presence }.first
          { name: name || "Anonymous", color: nil }
        end
      end

      # A stable, readable presence color per collaborator name.
      def collaborator_color(name)
        "hsl(#{name.to_s.each_byte.reduce(0) { |acc, b| ((acc * 31) + b) % 360 }}, 70%, 45%)"
      end
    end
  end
end

require "y/forms/collaborative_fields"
require "y/forms/form_builder"
