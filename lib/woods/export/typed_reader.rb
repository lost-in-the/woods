# frozen_string_literal: true

require 'woods/mcp/index_reader'

module Woods
  module Export
    # Typed reads for export consumers. Published identifiers remain unchanged.
    class TypedReader
      def initialize(reader)
        @reader = reader
      end

      # Refuse missing or mismatched identities instead of exporting a sibling.
      def find(identifier, type)
        unit = @reader.find_unit(identifier, type: type)
        unless unit.is_a?(Hash) && unit['identifier'] == identifier && unit['type'] == type
          raise ExtractionError, "export unit missing or mismatched: #{type}:#{identifier}"
        end

        unit
      rescue ArgumentError => e
        raise ExtractionError, "export reader requires typed lookup: #{e.message}"
      rescue IOError, SystemCallError, JSON::ParserError => e
        raise ExtractionError, "export unit unreadable: #{type}:#{identifier}: #{e.message}"
      end

      # IndexReader validates every published artifact, including mixed buckets.
      # The fallback supports injected readers with the documented list/find API.
      def all(only: nil)
        units = @reader.respond_to?(:each_unit) ? @reader.each_unit : injected_units(only)
        units.select { |unit| !only || only.include?(unit['type']) }
      rescue IOError, SystemCallError, JSON::ParserError => e
        raise ExtractionError, "export index incomplete: #{e.message}"
      end

      private

      def injected_units(only)
        MCP::IndexReader::UNIT_TYPES_BY_DIR.flat_map do |dir, types|
          next [] if only && (types & only).empty?

          @reader.list_units(type: MCP::IndexReader::DIR_TO_TYPE.fetch(dir)).map do |entry|
            find(entry['identifier'], entry_type(entry, types))
          end
        end
      end

      def entry_type(entry, types)
        type = entry['type'] || (types.first if types.one?)
        return type if types.include?(type)

        raise ExtractionError, "export entry requires actual type: #{entry['identifier']}"
      end
    end
  end
end
