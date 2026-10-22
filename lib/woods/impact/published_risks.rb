# frozen_string_literal: true

require_relative 'risk_budget'

module Woods
  module Impact
    # Adapts published structural flags; it does not compute graph analysis.
    class PublishedRisks
      # @param analysis [Hash] retained graph_analysis.json
      # @param units [Hash] actual typed inventory
      def initialize(analysis, units, budget: RiskBudget.new(10_000))
        raise IOError, 'Invalid published graph analysis' unless analysis.is_a?(Hash)

        @analysis = analysis
        @budget = budget
        @types = units.keys.group_by(&:first).transform_values { |keys| keys.map(&:last) }
      end

      # @param identity [Array(String, String)] selected typed unit
      # @return [Hash] structural risks and unavailable binding facts
      def call(identity)
        @risks = []
        @unknowns = []
        if @types.fetch(identity.first, []).size != 1
          return { 'risks' => [], 'unknowns' => [{ 'kind' => 'ambiguous_analysis_identity' }] }
        end

        reason = catch(:risk_budget) do
          named_flags(identity.first, 'hubs', 'hub', 'dependent_count')
          named_flags(identity.first, 'bridges', 'bridge', 'score')
          cycles(identity.first)
          cross_database(identity.first)
          nil
        end
        @unknowns << { 'kind' => reason } if reason
        { 'risks' => @risks, 'unknowns' => @unknowns }
      end

      private

      def entries(key)
        value = @analysis[key]
        return value if value.is_a?(Array)

        @unknowns << { 'kind' => "#{key}_unavailable" }
        []
      end

      def named_flags(identifier, family, kind, metric)
        entries(family).each do |record|
          @budget.consume
          raise IOError, 'Invalid named structural risk' unless record.is_a?(Hash)
          next unless record['identifier'] == identifier
          next if contradictory_type?(identifier, record)
          next unless record[metric].is_a?(Numeric) && record[metric].positive?

          add(kind, family, record)
        end
      end

      def contradictory_type?(identifier, record)
        return false unless record.key?('type') && record['type'] != @types.fetch(identifier).first

        @unknowns << { 'kind' => 'contradictory_analysis_type', 'published_type' => record['type'] }
        true
      end

      def cycles(identifier)
        entries('cycles').each do |cycle|
          @budget.consume
          inspect_cycle(cycle, identifier)
        end
        stats = @analysis['stats']
        return unless stats.is_a?(Hash) && stats['cycle_limit_reached']

        @unknowns << { 'kind' => 'published_cycles_truncated' }
      end

      def inspect_cycle(cycle, identifier)
        raise IOError, 'Invalid published cycle' unless cycle.is_a?(Array)
        return unless cycle.include?(identifier)

        unless cycle.all? { |id| @types.fetch(id, []).one? }
          @unknowns << { 'kind' => 'ambiguous_cycle_binding' }
          return
        end

        add('cycle', 'cycles', cycle)
      end

      def cross_database(identifier)
        entries('cross_database_edges').each do |edge|
          @budget.consume
          raise IOError, 'Invalid cross-database record' unless edge.is_a?(Hash)
          next unless [edge['from'], edge['to']].include?(identifier)

          if bound_cross_database?(edge)
            add('cross_database', 'cross_database_edges', edge)
          else
            @unknowns << { 'kind' => 'cross_database_binding_unavailable' }
          end
        end
      end

      def bound_cross_database?(edge)
        endpoints = edge.values_at('from', 'to')
        return false unless endpoints.all? { |id| @types.fetch(id, []).one? }

        databases = edge.values_at('from_db', 'to_db')
        return false unless databases.all?(String)

        databases << edge['through_db'] if edge['through'] && edge['through_db'].is_a?(String)
        databases.uniq.size > 1
      end

      def add(kind, family, fact)
        @risks << { 'kind' => kind, 'evidence' => { 'artifact' => 'graph_analysis.json',
                                                    'family' => family, 'fact' => fact } }
      end
    end
  end
end
