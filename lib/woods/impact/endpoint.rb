# frozen_string_literal: true

module Woods
  module Impact
    # Validated typed unit inventory from one locked published payload.
    class Endpoint
      # @param reader [PublishedIndex] caller retains ownership of its lock
      def initialize(reader)
        @reader = reader
      end

      # Historical tokens are unavailable; manifest checksum identifies the payload.
      # @param selector [String, Integer]
      # @return [Hash] endpoint provenance without host paths
      def provenance(selector)
        { 'selector' => selector, 'generation' => @reader.generation_number,
          'git_sha' => @reader.manifest['git_sha'], 'payload_checksum' => @reader.external_dependency_checksum }
      end

      # @return [Hash{Array(String, String) => Hash}] actual typed identities
      # @raise [IOError] if required inventory or fields are unavailable
      def units
        manifest = @reader.manifest
        validate_manifest!(manifest)
        records = @reader.each_unit.to_a
        raise IOError, 'Impact payload total_units mismatch' unless records.size == manifest['total_units']

        records.each_with_object({}) do |unit, result|
          validate_unit!(unit)
          identity = unit.values_at('identifier', 'type')
          raise IOError, 'Duplicate impact typed identity' if result.key?(identity)

          result[identity] = unit
        end
      end

      # @param units [Hash] validated typed units
      # @param side [String] from or to
      # @return [Array<Hash>] unavailable source facts, including unchanged units
      def unknowns(units, side)
        result = units.values.filter_map do |unit|
          next unless unit['source_code'].nil?

          unit.slice('identifier', 'type').merge('kind' => 'source_unavailable', 'endpoint' => side)
        end
        result.sort_by { |entry| entry.values_at('identifier', 'type') }
      end

      private

      def validate_manifest!(manifest)
        counts = manifest['counts']
        total = manifest['total_units']
        valid = counts.is_a?(Hash) && total.is_a?(Integer) && total >= 0 &&
                valid_counts?(counts) && counts.values.sum == total
        raise IOError, 'Impact requires manifest counts and total_units' unless valid
      end

      def valid_counts?(counts)
        counts.values.all? { |count| count.is_a?(Integer) && count >= 0 }
      end

      def validate_unit!(unit)
        valid = unit.key?('source_code') && (unit['source_code'].nil? || unit['source_code'].is_a?(String)) &&
                unit['metadata'].is_a?(Hash) && unit['dependencies'].is_a?(Array)
        raise IOError, 'Impact requires source_code, metadata and dependencies on every unit' unless valid
      end
    end
  end
end
