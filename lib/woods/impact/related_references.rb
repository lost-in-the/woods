# frozen_string_literal: true

module Woods
  module Impact
    # Resolves actual retained types without aliases or overriding conflicting hints.
    class ReferenceTarget
      def initialize(units)
        @types = units.keys.group_by(&:first).transform_values { |keys| keys.map(&:last) }
      end

      # @return [Array(Array, nil), Array(nil, String)] exact identity or unknown reason
      def resolve(record)
        identifier = record['target']
        return [nil, 'invalid_related_target'] unless identifier.is_a?(String) && !identifier.empty?

        candidates = @types.fetch(identifier, [])
        return [nil, 'related_target_unavailable'] if candidates.empty?

        type, reason = resolve_type(candidates, record['type'])
        reason ? [nil, reason] : [[identifier, type], nil]
      end

      private

      def resolve_type(candidates, hint)
        return [nil, 'conflicting_target_type'] unless hint.nil? || candidates.include?(hint)
        return [nil, 'ambiguous_target'] if hint.nil? && !candidates.one?

        [hint.nil? ? candidates.first : hint, nil]
      end
    end

    # Inspects direct published unit dependencies only, never another graph closure.
    class RelatedReferences
      TABLE_VIAS = %w[table migrates view_source reads_table writes_table foreign_key].freeze
      ATTRIBUTES = %w[via through through_db disable_joins].freeze

      def initialize(units, options:, budget:, context:)
        @units = units
        @options = options.to_h
        @budget = budget
        @context = context
        @targets = ReferenceTarget.new(units)
        @unknowns = []
      end

      attr_reader :unknowns

      # @yieldparam identity [Array] related candidate's exact typed identity
      # @yieldparam evidence [Hash] preserved directed dependency evidence
      def each(source)
        @units.fetch(source).fetch('dependencies').each do |record|
          @budget.consume_edge
          unless record.is_a?(Hash)
            unknown('invalid_related_dependency', source, {})
            next
          end
          next unless admitted?(source, record)

          target, reason = @targets.resolve(record)
          if reason
            unknown(reason, source, record)
            next
          end
          candidate = candidate(source, target, record['via'])
          next unless candidate && allowed?(candidate, record['via'])

          @budget.consume_node
          yield candidate, record.slice(*ATTRIBUTES).merge('kind' => 'published_relationship',
                                                           'source' => typed(source), 'target' => typed(target))
        end
      end

      private

      def admitted?(source, record)
        TABLE_VIAS.include?(record['via']) || record['via'] == 'render' ||
          (record['via'] == 'test_coverage' && source.last == 'test_mapping')
      end

      def candidate(source, target, via)
        return source if via == 'test_coverage'
        return target if target.last == 'database_table' && TABLE_VIAS.include?(via)
        return target if target.last == 'view_template' && via == 'render'

        nil
      end

      def allowed?(identity, via)
        (@options['types'].nil? || @options['types'].include?(identity.last)) &&
          (@options['via'].nil? || @options['via'].include?(via))
      end

      def typed(identity)
        { 'identifier' => identity.first, 'type' => identity.last }
      end

      def unknown(kind, source, record)
        @unknowns << @context.merge('kind' => kind, 'feature' => 'related', 'source' => typed(source),
                                    'edge' => record.slice('target', 'type', *ATTRIBUTES))
      end
    end
  end
end
