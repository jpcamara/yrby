# frozen_string_literal: true

require "active_support/concern"
require "base64"
require "json"
require "y/collaborative"

module Y
  module Forms
    # Adds a set of collaborative form fields to a model. The fields share one
    # collaborative document, which the model declares the same way
    # has_collaborative_document does. With column: the document is a column
    # of the model's own table instead, and forms need no connection.
    module CollaborativeFields
      extend ActiveSupport::Concern
      include Y::Collaborative

      module ClassMethods
        # Declares which attributes collaborate and resolves a tier for each:
        # :text (a Y.Text share, character merge) or :lww (an entry in the
        # shared map, last write wins per field). Rails enums are LWW; string
        # and text columns are text tier; every other type is LWW. The text:
        # and lww: kwargs force a tier and win over detection.
        #
        # column: names a string or text column that holds the document as
        # Base64. The form posts the document with the fields, and each save
        # merges it into the stored one (see Column).
        def has_collaborative_fields(*names, text: [], lww: [], encrypted: false, column: nil) # rubocop:disable Naming/PredicatePrefix
          include Model unless include?(Model)

          tiers = names.map(&:to_sym).to_h do |name|
            [name, forced_collaborative_tiers(names, text, lww)[name] || detect_collaborative_tier(name)]
          end
          self.collaborative_field_tiers = collaborative_field_tiers.merge(tiers).freeze
          return collaborative_fields_in(column, encrypted:) if column

          # encrypted: true stores the document through Y::EncryptedDocument.
          # To encrypt the columns the values are written to, use the model's
          # own +encrypts+.
          has_collaborative_document Y::Forms::DOCUMENT_NAME, encrypted:, channel: Y::Forms::CHANNEL_NAME

          # The document's row, or nil before the first edit. The association
          # is here so that destroying the record destroys its document.
          has_one :collaborative_fields_document, -> { where(name: Y::Forms::DOCUMENT_NAME) },
                  class_name: encrypted ? "Y::EncryptedDocument" : "Y::Document",
                  as: :record, inverse_of: :record, dependent: :destroy
        end

        private

        def collaborative_fields_in(column, encrypted:)
          unless attribute_types.key?(column.to_s)
            raise ArgumentError, "#{column.inspect} is not an attribute of #{name}"
          end
          raise ArgumentError, "encrypted: has no effect with column:, use encrypts #{column.inspect}" if encrypted

          include Column unless include?(Column)
          self.collaborative_fields_column = column.to_sym
        end

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

        # The column holding the document, or nil when it is a Y::Document.
        def collaborative_fields_column = nil

        # Reads the document and writes the declared fields' current values
        # into their columns while holding the record lock. Returns false
        # before the document's first edit.
        def refresh_collaborative_fields
          with_lock do
            state = collaborative_document(Y::Forms::DOCUMENT_NAME).load_state
            break false if state.nil?

            doc = Y::Doc.new
            doc.apply_update(state)
            assign_collaborative_fields(doc)
            save!(validate: false) # collaboration updates should not run unrelated model validations
            true
          end
        end

        private

        def collaborative_text_name(name) = "#{Y::Forms::DOCUMENT_NAME}/#{name}"

        # Assign declared fields only, each read through its declared tier.
        # The map is client-written, so any key a client invents — another
        # column's name included — is dropped here; nothing outside the
        # declared set is ever mass-assigned. LWW values cast through the
        # attribute types on assignment.
        def assign_collaborative_fields(doc)
          entries = JSON.parse(doc.read_map(Y::Forms::DOCUMENT_NAME) || "{}")
          collaborative_field_tiers.each do |name, tier|
            if tier == :text
              value = doc.read_text(collaborative_text_name(name))
              assign_attributes(name => value) unless value.nil?
            elsif entries.key?(name.to_s)
              assign_attributes(name => entries[name.to_s])
            end
          end
        end
      end

      # The document in a column of the model's own table, as Base64. A form
      # posts the document it edited in that column's param, next to the
      # fields. Each save merges the posted document into the stored one and
      # reads the declared fields from the result, so two people who submit
      # the same form both keep their edits.
      #
      # The document owns the declared fields: a value assigned to one in Ruby
      # is replaced by the document's on save. A text field the document does
      # not hold yet is added to it from its column, which is how a record
      # created in Ruby, or one saved before the macro was declared, gets its
      # document.
      module Column
        extend ActiveSupport::Concern

        included do
          class_attribute :collaborative_fields_column, instance_writer: false
          before_save :merge_collaborative_fields
        end

        # The document a form starts from: the stored one, or before the first
        # save one built from the text columns.
        def collaborative_fields_state
          self[collaborative_fields_column].presence || encode_collaborative_fields(seed_collaborative_fields(Y::Doc.new))
        end

        private

        def merge_collaborative_fields
          column = collaborative_fields_column
          watched = [column, *collaborative_field_tiers.keys]
          return if self[column].present? && watched.none? { |name| will_save_change_to_attribute?(name) }

          doc = load_collaborative_fields(stored_collaborative_fields, self[column])
          assign_collaborative_fields(seed_collaborative_fields(doc))
          self[column] = encode_collaborative_fields(doc)
        end

        # Read under a row lock, so two saves at once merge one after the other.
        def stored_collaborative_fields
          return unless persisted?

          self.class.unscoped.lock.where(self.class.primary_key => id_in_database).pick(collaborative_fields_column)
        end

        def load_collaborative_fields(*states)
          states.compact_blank.each_with_object(Y::Doc.new) do |state, doc|
            doc.apply_update(Base64.strict_decode64(state))
          end
        rescue ArgumentError, Y::Error
          errors.add(collaborative_fields_column, :invalid)
          throw :abort
        end

        def seed_collaborative_fields(doc)
          collaborative_field_tiers.each do |name, tier|
            next unless tier == :text && self[name].present? && doc.read_text(collaborative_text_name(name)).nil?

            doc.get_text(collaborative_text_name(name)).insert(0, self[name].to_s)
          end
          doc
        end

        def encode_collaborative_fields(doc) = Base64.strict_encode64(doc.encode_state_as_update)
      end
    end
  end
end
