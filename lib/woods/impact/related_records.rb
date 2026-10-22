# frozen_string_literal: true

require_relative 'value'

module Woods
  module Impact
    # Deduplicates endpoint-specific facts while retaining distinct directed evidence.
    class RelatedRecords
      FAMILIES = { 'database_table' => 'tables', 'view_template' => 'templates', 'test_mapping' => 'tests' }.freeze

      def initialize(units, context:)
        @units = units
        @context = context
        @records = FAMILIES.values.to_h { |family| [family, {}] }
        @unknowns = []
      end

      attr_reader :unknowns

      def add(identity, evidence)
        family = FAMILIES[identity.last]
        return unless family

        record = (@records.fetch(family)[identity] ||= build(identity))
        record['evidence'] << evidence unless record['evidence'].include?(evidence)
      end

      def to_h
        @records.transform_values do |records|
          records.sort.map do |_identity, record|
            record.merge('evidence' => record['evidence'].sort_by { |evidence| Value.json(evidence) })
          end
        end
      end

      private

      def build(identity)
        record = @context.merge('identifier' => identity.first, 'type' => identity.last, 'evidence' => [])
        return record unless identity.last == 'database_table'

        metadata = @units.fetch(identity).fetch('metadata')
        missing = %w[table_name database].reject { |key| metadata[key].is_a?(String) }
        unless missing.empty?
          @unknowns << @context.merge('kind' => 'related_table_metadata_unavailable', 'metadata_keys' => missing,
                                      'identifier' => identity.first, 'type' => identity.last)
        end
        record.merge(%w[table_name database].to_h { |key| [key, metadata[key].is_a?(String) ? metadata[key] : nil] })
      end
    end

    # Reuses the last recorded edge of existing affected witnesses, without traversal.
    class RelatedWitnesses
      def initialize(records, context:)
        @records = records
        @context = context
        @unknowns = []
      end

      attr_reader :unknowns

      def add(affected)
        affected.each do |item|
          Array(item['paths']).each { |path| add_path(item, path) }
        end
      end

      private

      def add_path(item, path)
        identity = item.values_at('identifier', 'type')
        edge = path.fetch('edges').last
        unless [item, path].all? { |value| value.slice('endpoint', 'generation') == @context } &&
               edge && edge['source'] == item.slice('identifier', 'type')
          @unknowns << @context.merge('kind' => 'related_witness_context_unavailable',
                                      'identifier' => identity.first, 'type' => identity.last)
          return
        end
        return unless admitted?(identity.last, edge['via'])

        @records.add(identity, edge.merge('kind' => 'published_relationship'))
      end

      def admitted?(type, via)
        (type == 'test_mapping' && via == 'test_coverage') ||
          (type == 'view_template' && %w[render view_render].include?(via)) ||
          (type == 'database_table' && RelatedReferences::TABLE_VIAS.include?(via))
      end
    end
  end
end
