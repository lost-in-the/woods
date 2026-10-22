# frozen_string_literal: true

require_relative 'propagation'
require_relative 'flows'
require_relative 'risks'
require_relative 'related'

module Woods
  module Impact
    # Dispatches removed roots to base evidence and current roots to head evidence.
    # Results retain endpoint/generation context rather than combining typed names.
    class Enrichment
      # @param options [Options]
      def initialize(options)
        @options = options
        @statuses = %w[affected flows risks tables templates tests].to_h { |key| [key, []] }
        @result = @statuses.transform_values { [] }.merge('unknowns' => [], 'coverage' => {})
        %w[tables templates tests].each { |key| @statuses[key] << 'partial' }
      end

      # @param reader [PublishedIndex] still locked
      # @param units [Hash] typed inventory from that reader
      # @param roots [Array<Array(String, String)>] roots belonging to that endpoint
      # @param endpoint [String]
      # @return [void]
      def add(reader, units, roots, endpoint, comparison: nil)
        return if roots.empty?

        artifacts = Artifacts.new(reader)
        arguments = { generation: reader.generation_number, endpoint: endpoint, options: @options }
        budget = GraphBudget.new(@options)
        propagation = propagate(artifacts, units, roots, arguments, budget)
        flows = Flows.new(artifacts, **arguments).call(roots)
        collect('affected', propagation)
        collect('flows', flows)
        identities = roots + propagation['affected'].map { |item| item.values_at('identifier', 'type') }
        collect_risks(reader, units, identities, endpoint, comparison)
        collect_related(units, identities, propagation['affected'], arguments, budget)
      end

      # @return [Hash] deterministic bounded enrichment and query parameters
      def to_h
        @result['coverage'] = @statuses.transform_values do |statuses|
          statuses.any? { |status| %w[partial unavailable].include?(status) } ? 'partial' : 'bounded'
        end
        @result.merge('parameters' => @options.to_h.merge('mode' => 'range', 'artifact_max_bytes' => Artifacts::MAX_BYTES))
      end

      private

      def collect_risks(reader, units, identities, endpoint, comparison)
        context = { 'generation' => reader.generation_number, 'endpoint' => endpoint }
        risks = Risks.new(reader, units, context: context, limit: @options.to_h.fetch('max_risk_records'))
        collect('risks', risks.call(identities, comparison: comparison))
      end

      def collect_related(units, identities, affected, arguments, budget)
        data = Related.new(units, **arguments, budget: budget).call(identities, affected: affected)
        %w[tables templates tests].each do |key|
          @result[key].concat(data.fetch(key))
          @statuses[key] << data.fetch('coverage')
        end
        @result['unknowns'].concat(data.fetch('unknowns'))
      end

      def propagate(artifacts, units, roots, arguments, budget)
        graph = artifacts.read('dependency_graph.json')
        Propagation.new(graph, units, **arguments, budget: budget).call(roots)
      rescue *Flows::READ_ERRORS
        { 'affected' => [], 'coverage' => 'unavailable',
          'unknowns' => [arguments.slice(:generation, :endpoint).transform_keys(&:to_s)
                                  .merge('kind' => 'graph_unavailable')] }
      end

      def collect(key, data)
        @result[key].concat(data.fetch(key))
        @result['unknowns'].concat(data.fetch('unknowns'))
        @statuses[key] << data.fetch('coverage')
      end
    end
  end
end
