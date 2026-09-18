# frozen_string_literal: true

module Woods
  module SessionTracer
    # A bare dependency name cannot choose between published extraction types.
    class AmbiguousUnitError < StandardError
      attr_reader :identifier, :types

      def initialize(identifier, types)
        @identifier = identifier
        @types = types.sort.freeze
        super("Ambiguous session unit #{identifier.inspect}: published types #{@types.join(', ')}. " \
              'No session context was returned. Use depth: 0 for the timeline, or inspect each type with lookup.')
      end
    end

    # Per-assembly resolver. The caller pins its complete lifetime to one generation.
    # Summary entries may omit type in legacy indexes; the containing bucket and
    # validated unit body establish the concrete type without reading unrelated bodies.
    class UnitResolver
      def initialize(reader)
        @reader = reader
        @resolved = {}
      end

      def find(identifier)
        return @resolved[identifier] if @resolved.key?(identifier)

        units = candidate_types.fetch(identifier, []).filter_map do |type|
          @reader.find_unit(identifier, type: type)
        end
        raise AmbiguousUnitError.new(identifier, units.map { |unit| unit.fetch('type') }) if units.size > 1

        @resolved[identifier] = units.first
      end

      private

      def entries_for(dir)
        path = @reader.payload_dir.join(dir, '_index.json')
        raise IOError, "symlink unit index: #{dir}" if path.symlink?

        entries = @reader.list_units(type: MCP::IndexReader::DIR_TO_TYPE.fetch(dir))
        expected = @reader.manifest.dig('counts', dir)
        if expected.is_a?(Integer) && expected != entries.size
          raise IOError, "unit count mismatch in #{dir}: expected #{expected}, found #{entries.size}"
        end

        entries
      end

      def candidate_types
        @candidate_types ||= MCP::IndexReader::UNIT_TYPES_BY_DIR.each_with_object({}) do |(dir, types), candidates|
          entries_for(dir).each do |entry|
            identifier = entry.fetch('identifier')
            candidates[identifier] ||= []
            candidates[identifier] |= types
          end
        end
      end
    end
  end
end
