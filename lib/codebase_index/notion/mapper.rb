# frozen_string_literal: true

require_relative 'mappers/model_mapper'
require_relative 'mappers/column_mapper'
require_relative 'mappers/migration_mapper'

module CodebaseIndex
  module Notion
    # Dispatcher for Notion mappers. Returns the appropriate mapper for a unit type.
    #
    # @example
    #   mapper = Mapper.for("model")
    #   properties = mapper.map(unit_data)
    #
    class Mapper
      REGISTRY = {
        'model' => Mappers::ModelMapper,
        'column' => Mappers::ColumnMapper,
        'migration' => Mappers::MigrationMapper
      }.freeze

      # Get a mapper instance for a unit type.
      #
      # @param type [String] Unit type name (e.g. "model", "column", "migration")
      # @return [Object, nil] Mapper instance or nil if type is not supported
      def self.for(type)
        klass = REGISTRY[type]
        klass&.new
      end

      # List all supported unit types.
      #
      # @return [Array<String>]
      def self.supported_types
        REGISTRY.keys
      end
    end
  end
end
