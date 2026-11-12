# frozen_string_literal: true

module Y
  # Support for the pg_yrby Postgres extension, which stores documents in a
  # ydoc column. See Y::PgDocument.
  module PgYrby
    # Teaches a PostgreSQL adapter class that ydoc reads and writes like
    # bytea (it is the same bytes), so Active Record doesn't warn about an
    # unknown type and returns binary strings. Connections made after this
    # pick it up; the engine calls it when the adapter loads.
    def self.register_type(adapter_class)
      return if adapter_class.singleton_class.include?(TypeMap)

      adapter_class.singleton_class.prepend(TypeMap)
    end

    module TypeMap
      def initialize_type_map(map)
        super
        map.register_type "ydoc", ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Bytea.new
      end
    end
  end
end
