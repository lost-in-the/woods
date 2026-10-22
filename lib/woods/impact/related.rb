# frozen_string_literal: true

require_relative 'related_references'
require_relative 'related_records'
require_relative 'graph_budget'

module Woods
  module Impact
    # Bounded related table/template/test evidence from retained typed selections.
    class Related
      LIMITS = %w[database_access_not_exhaustive render_references_only test_suggestions_only].freeze

      def initialize(units, generation:, endpoint:, options:, budget:)
        @budget = budget
        @context = { 'endpoint' => endpoint, 'generation' => generation }
        @records = RelatedRecords.new(units, context: @context)
        @references = RelatedReferences.new(units, context: @context, options: options, budget: budget)
        @witnesses = RelatedWitnesses.new(@records, context: @context)
      end

      # @param identities [Array<Array>] roots plus already affected exact typed units
      # @param affected [Array<Hash>] existing generation-bound propagation records
      # @return [Hash] partial related arrays, unknowns and coverage
      def call(identities, affected: [])
        reason = catch(:impact_budget) do
          identities.uniq.sort.each { |identity| inspect_unit(identity) }
          nil
        end
        @witnesses.add(affected)
        unknowns = LIMITS.map { |kind| @context.merge('kind' => kind) }
        unknowns.concat(@references.unknowns + @records.unknowns + @witnesses.unknowns)
        unknowns << @context.merge('kind' => reason, 'feature' => 'related') if reason
        @records.to_h.merge('coverage' => 'partial', 'unknowns' => unknowns.uniq)
      end

      private

      def inspect_unit(identity)
        @budget.consume_node
        @records.add(identity, 'kind' => 'selected_unit')
        @references.each(identity) { |target, evidence| @records.add(target, evidence) }
      end
    end
  end
end
