# frozen_string_literal: true

module Woods
  module Resilience
    class GraphInvariantValidator
      # The additive reverse relationship index must preserve every typed
      # forward record. Legacy graphs can omit it entirely.
      module ReverseRelationshipChecks
        RELATIONSHIP_KEYS = %w[via through through_db disable_joins].freeze

        private

        def record_reverse_relationship(target, source, source_type, edge)
          return unless name?(source) && name?(source_type)

          attributes = edge.is_a?(Hash) ? edge.slice(*RELATIONSHIP_KEYS) : {}
          record = { 'source' => source, 'source_type' => source_type, 'via' => nil }.merge(attributes)
          @expected_reverse_via[target] << record
        end

        def validate_reverse_relationships
          return unless @graph.key?('reverse_via')

          actual = object_section('reverse_via')
          (@expected_reverse_via.keys | actual.keys).each do |target|
            compare_reverse_relationships(target, actual.fetch(target, []))
          end
        end

        def compare_reverse_relationships(target, rows)
          label = "reverse_via[#{target.inspect}]"
          unless name?(target) && rows.is_a?(Array) && rows.all?(Hash)
            error(label, 'expected a named bucket containing relationship objects')
            return
          end
          expected = @expected_reverse_via.fetch(target, [])
          keys = %w[source source_type] + RELATIONSHIP_KEYS
          recorded = rows.map { |row| row.slice(*keys) }
          return if expected.tally == recorded.tally

          error(label, 'relationship records differ from typed forward edges')
        end
      end
    end
  end
end
