# frozen_string_literal: true

require 'digest'
require 'json'

module Woods
  module Temporal
    # Projects extraction units into the fingerprint records snapshot stores consume.
    #
    # @api private
    module SnapshotUnitFacts
      module_function

      # Keep group/unit order and each unit's actual type. Fingerprints retain
      # the existing to_json dispatch and byte order: canonicalizing values
      # here would change comparisons against previously captured snapshots.
      #
      # @param unit_groups [Enumerable<Array<ExtractedUnit>>] ordered groups of units
      # @return [Array<Hash{String => String}>] snapshot identity and content fingerprints
      def build(unit_groups:)
        unit_groups.flat_map do |units|
          units.map { |unit| unit_facts(unit) }
        end
      end

      def unit_facts(unit)
        {
          'identifier' => unit.identifier,
          'type' => unit.type.to_s,
          'source_hash' => Digest::SHA256.hexdigest(unit.source_code.to_s),
          'metadata_hash' => Digest::SHA256.hexdigest(unit.metadata.to_json),
          'dependencies_hash' => Digest::SHA256.hexdigest(unit.dependencies.to_json)
        }
      end
      private_class_method :unit_facts
    end
  end
end
