# frozen_string_literal: true

require "active_support/concern"
require "json"

module Y
  module Forms
    # Adds a Y::Document-backed set of collaborative form fields to a model.
    # A thin adapter over Y::Collaborative: has_collaborative_fields
    # declares one collaborative document named "fields" whose materialize
    # step reads each declared field through its tier and assigns the
    # column.
    module CollaborativeFields
      extend ActiveSupport::Concern
      include Y::Collaborative

      module ClassMethods
        # Declares which attributes collaborate and resolves a tier for each:
        # :text (a Y.Text share, character merge) or :lww (an entry in the
        # shared map, last write wins per field). Rails enums are LWW; string
        # and text columns are text tier; every other type is LWW. The text:
        # and lww: kwargs force a tier and win over detection.
        def has_collaborative_fields(*names, text: [], lww: [], encrypted: false) # rubocop:disable Naming/PredicatePrefix
          include Model unless include?(Model)

          tiers = names.map(&:to_sym).to_h do |name|
            [name, forced_collaborative_tiers(names, text, lww)[name] || detect_collaborative_tier(name)]
          end
          self.collaborative_field_tiers = collaborative_field_tiers.merge(tiers).freeze

          # The base owns the association, the sgid flow, and the refresh
          # shell; the block is this gem's whole contribution to it.
          has_collaborative_document(Y::Forms::DOCUMENT_NAME, encrypted: encrypted) do |doc, record|
            record.send(:assign_collaborative_fields, doc)
          end
        end

        private

        def forced_collaborative_tiers(names, text, lww)
          forced = Array(text).to_h { |name| [name.to_sym, :text] }
          Array(lww).each do |name|
            raise ArgumentError, "#{name.inspect} is forced both text: and lww:" if forced.key?(name.to_sym)

            forced[name.to_sym] = :lww
          end
          unknown = forced.keys - names.map(&:to_sym)
          raise ArgumentError, "#{unknown.map(&:inspect).join(", ")} not declared collaborative" if unknown.any?

          forced
        end

        def detect_collaborative_tier(name)
          unless attribute_types.key?(name.to_s)
            raise ArgumentError, "#{name.inspect} is not an attribute of #{self.name}"
          end
          return :lww if defined_enums.key?(name.to_s)

          %i[string text].include?(type_for_attribute(name).type) ? :text : :lww
        end
      end

      # The instance API, present only on models that declared fields.
      # The field-set spellings delegate to the base's document API under
      # the "fields" name.
      module Model
        extend ActiveSupport::Concern

        included do
          class_attribute :collaborative_field_tiers, instance_writer: false, default: {}.freeze
        end

        def collaborative_fields? = collaborative_field_tiers.any?

        def collaborative_field?(name) = collaborative_field_tiers.key?(name.to_sym)

        # The document, if collaboration has started (nil until the first join).
        def collaborative_fields_document = collaborative_document(Y::Forms::DOCUMENT_NAME)

        # Creates the document on first use. The association supplies the
        # class, so an encrypted field set gets a Y::EncryptedDocument.
        def find_or_create_collaborative_fields_document
          find_or_create_collaborative_document(Y::Forms::DOCUMENT_NAME)
        end

        # Materializes the declared fields into their columns; the base
        # shell holds the record lock and saves with validate: false.
        # Returns false when the document has no state.
        def refresh_collaborative_fields = refresh_collaborative_document(Y::Forms::DOCUMENT_NAME)

        private

        # Assign declared fields only, each read through its declared tier.
        # The map is client-written, so any key a client invents — another
        # column's name included — is dropped here; nothing outside the
        # declared set is ever mass-assigned. LWW values cast through the
        # attribute types on assignment.
        def assign_collaborative_fields(doc)
          entries = JSON.parse(doc.read_map(Y::Forms::DOCUMENT_NAME) || "{}")
          collaborative_field_tiers.each do |name, tier|
            if tier == :text
              value = doc.read_text("#{Y::Forms::DOCUMENT_NAME}/#{name}")
              assign_attributes(name => value) unless value.nil?
            elsif entries.key?(name.to_s)
              assign_attributes(name => entries[name.to_s])
            end
          end
        end
      end
    end
  end
end
