# frozen_string_literal: true

require "y"

module Y
  # Collaborative form fields over yrby: a model macro
  # (has_collaborative_fields), form helpers rendering the
  # <collaborative-form> / <collaborative-field> elements, and an install
  # generator for the channel. One Y::Document per record holds the whole
  # field set: LWW fields in a "fields" map share, text-tier fields in one
  # "fields/<name>" text share each.
  module Forms
    # Signed ids from the form helper carry this purpose scoped to the
    # field-set document (sgid_purpose), so a token minted elsewhere can't
    # join it.
    SGID_PURPOSE = :y_forms

    # The channel the installer generates and the form helper points elements at.
    CHANNEL_NAME = "FormFieldsChannel"

    # The Y::Document name for a record's field set: one document per record.
    DOCUMENT_NAME = "fields"

    class << self
      def sgid_purpose = "#{SGID_PURPOSE}/#{DOCUMENT_NAME}"

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
