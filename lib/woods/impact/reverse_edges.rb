# frozen_string_literal: true

require_relative 'value'

module Woods
  module Impact
    # Adapter over published reverse_via; never reconstructs or analyses a graph.
    class ReverseEdges
      # @param graph [Hash] one retained dependency_graph.json
      # @param units [Hash] validated actual typed inventory
      def initialize(graph, units)
        raise IOError, 'Impact graph lacks reverse_via' unless graph.is_a?(Hash) && graph['reverse_via'].is_a?(Hash)

        @graph = graph
        @units = units
        @types = units.keys.group_by(&:first).transform_values { |keys| keys.map(&:last).sort }
      end

      # @param identity [Array(String, String)] target identity
      # @return [Array<Hash>] published ordering; examination is charged before use
      def records(identity)
        records = @graph.fetch('reverse_via').fetch(identity.first, [])
        raise IOError, 'Impact reverse_via bucket is not an array' unless records.is_a?(Array)

        records
      end

      # @param identity [Array(String, String)] exact target
      # @param record [Hash] published reverse record
      # @return [Array(Array, Hash), String, nil] source/edge, unknown kind, or another target type
      def resolve(identity, record)
        raise IOError, 'Invalid reverse_via record' unless valid_record?(record)

        source = record.values_at('source', 'source_type')
        return 'unresolved_source' unless @units.key?(source)

        target_type = resolve_type(identity.first, record['type'])
        return target_type unless @types.fetch(identity.first, []).include?(target_type)
        return unless target_type == identity.last

        [source, record.slice('via', 'through', 'through_db', 'disable_joins')
                       .merge('source' => typed(source), 'target' => typed(identity))]
      end

      # PageRank is published by bare identifier; collisions cannot get typed weights.
      # @param identity [Array(String, String)]
      # @return [Array(Float, String), Array(nil, String)] score and unknown reason
      def weight(identity)
        return [nil, 'ambiguous_weight'] unless @types.fetch(identity.first, []).one?

        ranks = @graph['pagerank']
        value = ranks.is_a?(Hash) && ranks[identity.first]
        return [nil, 'pagerank_unavailable'] unless value.is_a?(Numeric) && value.finite? && value >= 0

        [value, nil]
      end

      private

      def resolve_type(identifier, hint)
        candidates = @types.fetch(identifier, [])
        return 'conflicting_target_type' if hint && !candidates.include?(hint)
        return hint if hint

        candidates.one? ? candidates.first : 'ambiguous_target'
      end

      def typed(identity)
        { 'identifier' => identity.first, 'type' => identity.last }
      end

      def valid_record?(record)
        record.is_a?(Hash) && %w[source source_type].all? do |key|
          record[key].is_a?(String) && !record[key].empty?
        end
      end
    end
  end
end
