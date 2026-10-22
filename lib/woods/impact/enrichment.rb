# frozen_string_literal: true

require_relative 'propagation'
require_relative 'flows'
require_relative 'risks'

module Woods
  module Impact
    # Dispatches removed roots to base evidence and current roots to head evidence.
    # Results retain endpoint/generation context rather than combining typed names.
    class Enrichment
      # @param options [Options]
      def initialize(options)
        @options = options
        @result = { 'affected' => [], 'flows' => [], 'risks' => [], 'unknowns' => [], 'coverage' => {} }
        @statuses = { 'affected' => [], 'flows' => [], 'risks' => [] }
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
        propagation = propagate(artifacts, units, roots, arguments)
        flows = Flows.new(artifacts, **arguments).call(roots)
        collect('affected', propagation)
        collect('flows', flows)
        identities = roots + propagation['affected'].map { |item| item.values_at('identifier', 'type') }
        collect_risks(reader, units, identities, endpoint, comparison)
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

      def propagate(artifacts, units, roots, arguments)
        graph = artifacts.read('dependency_graph.json')
        Propagation.new(graph, units, **arguments).call(roots)
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
