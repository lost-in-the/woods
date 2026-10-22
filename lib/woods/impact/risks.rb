# frozen_string_literal: true

require_relative 'metadata_risks'
require_relative 'published_risks'
require_relative 'artifacts'

module Woods
  module Impact
    # Retained risk evidence for changed/affected/focused typed units.
    class Risks
      # @param reader [PublishedIndex] locked endpoint
      # @param units [Hash] endpoint's typed inventory
      # @param context [Hash] endpoint/generation
      # @param limit [Integer] shared risk record budget
      def initialize(reader, units, context:, limit:)
        @reader = reader
        @units = units
        @context = context
        @budget = RiskBudget.new(limit)
        @risks = []
        @unknowns = [context.merge('kind' => 'instance_variable_mismatch_not_computed')]
      end

      # @param identities [Array<Array(String, String)>]
      # @param comparison [Hash, nil] other endpoint's typed inventory
      # @return [Hash] risks, unknowns, coverage
      def call(identities, comparison: nil)
        published = published_analysis
        reason = catch(:risk_budget) do
          identities.uniq.sort.each do |identity|
            @budget.consume
            inspect_unit(identity, comparison, published)
          end
          nil
        end
        @unknowns << @context.merge('kind' => reason) if reason
        { 'risks' => @risks, 'unknowns' => @unknowns.uniq, 'coverage' => 'partial' }
      end

      private

      def published_analysis
        data = Artifacts.new(@reader).read('graph_analysis.json')
        PublishedRisks.new(data, @units, budget: @budget)
      rescue IOError, SystemCallError, JSON::ParserError
        @unknowns << @context.merge('kind' => 'graph_analysis_unavailable')
        nil
      end

      def inspect_unit(identity, comparison, published)
        unit = @units.fetch(identity)
        other = comparison&.dig(identity, 'metadata')
        pair = @context['endpoint'] == 'from' ? [unit['metadata'], other] : [other, unit['metadata']]
        collect(identity, MetadataRisks.new(identity.last, budget: @budget).call(*pair, current: unit['metadata']))
        collect(identity, published.call(identity)) if published
      rescue IOError
        @unknowns << @context.merge('kind' => 'structural_risk_evidence_invalid',
                                    'identifier' => identity.first, 'type' => identity.last)
      end

      def collect(identity, result)
        typed = { 'identifier' => identity.first, 'type' => identity.last }
        @risks.concat(result['risks'].map { |risk| @context.merge(risk).merge('unit' => typed) })
        @unknowns.concat(result['unknowns'].map { |unknown| @context.merge(typed).merge(unknown) })
      end
    end
  end
end
