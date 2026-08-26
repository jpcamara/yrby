# frozen_string_literal: true

require "active_support/concern"
require "json"

module Y
  module Forms
    # Adds a Y::Document-backed set of collaborative form fields to a model.
    module CollaborativeFields
      extend ActiveSupport::Concern

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

          # encrypted: true stores CRDT state through Y::EncryptedDocument.
          # Encrypting the materialized columns themselves is the model's own
          # +encrypts+ declaration.
          document_class = encrypted ? "Y::EncryptedDocument" : "Y::Document"
          has_one :collaborative_fields_document, -> { where(name: Y::Forms::DOCUMENT_NAME) },
                  class_name: document_class, as: :record, inverse_of: :record, dependent: :destroy
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
      module Model
        extend ActiveSupport::Concern

        included do
          class_attribute :collaborative_field_tiers, instance_writer: false, default: {}.freeze
        end

        def collaborative_fields? = collaborative_field_tiers.any?

        def collaborative_field?(name) = collaborative_field_tiers.key?(name.to_sym)

        # The document, if collaboration has started (nil until the first join).
        def collaborative_document = collaborative_fields_document

        # Creates the document on first use. The association supplies the
        # class, so an encrypted field set gets a Y::EncryptedDocument.
        def find_or_create_collaborative_fields_document
          collaborative_fields_document || begin
            association(:collaborative_fields_document).klass.for(self, Y::Forms::DOCUMENT_NAME)
            reload_collaborative_fields_document
          end
        end

        # Reloads the document and writes the declared fields' current values
        # into their columns while holding the record lock. Returns false
        # when the document has no state.
        def refresh_collaborative_fields
          document = collaborative_fields_document
          return false unless document

          with_lock do
            state = document.reload.load_state
            break false if state.nil?

            doc = Y::Doc.new
            doc.apply_update(state)
            assign_collaborative_fields(doc)
            save!(validate: false) # collaboration updates should not run unrelated model validations
            true
          end
        end

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
