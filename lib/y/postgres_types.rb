# frozen_string_literal: true

module Y
  # Teaches a PostgreSQL adapter class the column types of the insert-only
  # log (y_document_updates.txid, y_documents.folded), which only SQL reads,
  # so Active Record doesn't warn about unknown types. Connections made after
  # this pick it up; the engine calls it when the adapter loads.
  module PostgresTypes
    def self.register(adapter_class)
      return if adapter_class.singleton_class.include?(TypeMap)

      adapter_class.singleton_class.prepend(TypeMap)
    end

    module TypeMap
      def initialize_type_map(map)
        super
        %w[xid8 pg_snapshot].each do |type|
          map.register_type type, ActiveRecord::ConnectionAdapters::PostgreSQL::OID::SpecializedString.new(type.to_sym)
        end
      end
    end
  end
end
