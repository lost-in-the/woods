# frozen_string_literal: true

require_relative 'artifacts'
require_relative 'options'
require_relative 'flow_calls'

module Woods
  module Impact
    # Retained W13 membership and documents. Never assembles flows at read time.
    class Flows
      READ_ERRORS = [IOError, SystemCallError, JSON::ParserError].freeze

      # @param artifacts [Artifacts] bounded reader for the selected endpoint
      # @param generation [Integer]
      # @param endpoint [String] from or to
      # @param options [Options]
      def initialize(artifacts, generation:, endpoint:, options:)
        @artifacts = artifacts
        @context = { 'generation' => generation, 'endpoint' => endpoint }
        @budget = options.to_h
        @flows = []
        @unknowns = [@context.merge('kind' => 'expanded_membership_only')]
        @partial = false
      end

      # @param roots [Array<Array(String, String)>] exact changed identities
      # @return [Hash] flows, unknowns, coverage
      def call(roots)
        inverse = @artifacts.read('flows/by_unit.json')
        @index = @artifacts.read('flows/flow_index.json')
        raise IOError, 'Invalid flow indexes' unless inverse.is_a?(Hash) && @index.is_a?(Hash)

        reason = catch(:flow_budget) do
          memberships(inverse, roots).sort.each { |entry, identities| document(entry, identities) }
          nil
        end
        mark_unknown(reason) if reason
        response(@partial ? 'partial' : 'expanded_membership')
      rescue *READ_ERRORS
        mark_unknown('flow_index_unavailable')
        response('unavailable')
      end

      private

      def memberships(inverse, roots)
        result = Hash.new { |hash, key| hash[key] = [] }
        roots.sort.each do |identity|
          typed = inverse.fetch(identity.first, {})
          raise IOError, 'Invalid typed flow inverse' unless typed.is_a?(Hash)

          entries = typed.fetch(identity.last, [])
          raise IOError, 'Invalid flow inverse membership' unless entries.is_a?(Array)

          entries.each { |entry| add_membership(result, entry, identity) }
        end
        result
      end

      def add_membership(result, entry, identity)
        consume('max_flow_steps', 'flow_membership_budget')
        raise IOError, 'Invalid entry point' unless entry.is_a?(String) && !entry.empty?

        result[entry] << { 'identifier' => identity.first, 'type' => identity.last }
      end

      def document(entry, identities)
        consume('max_flow_documents', 'flow_document_budget')
        data = @artifacts.read(@index.fetch(entry))
        steps = validated_steps(data, entry)
        members = steps.filter_map { |step| step_identity(step) }
        raise IOError, 'Flow document contradicts inverse' unless (identities - members).empty?

        @flows << @context.merge('entry_point' => entry, 'route' => data['route']&.slice('verb', 'path'),
                                 'changed_steps' => identities.uniq)
        steps.each { |step| inspect_step(step, entry) }
      rescue *READ_ERRORS, KeyError
        mark_unknown('invalid_flow_document', 'entry_point' => entry)
      end

      def validated_steps(data, entry)
        unless data.is_a?(Hash) && data['entry_point'] == entry && data['steps'].is_a?(Array) &&
               (data['route'].nil? || data['route'].is_a?(Hash))
          raise IOError, 'Invalid flow document'
        end

        data['steps'].each { consume('max_flow_steps', 'flow_step_budget') }
        data['steps']
      end

      def step_identity(step)
        raise IOError, 'Invalid flow step' unless step.is_a?(Hash)
        return if step['type'] == 'cycle'
        unless step['unit'].is_a?(String) && step['type'].is_a?(String) && !step['type'].empty?
          raise IOError, 'Invalid typed flow step'
        end

        identifier = step['unit'].split('#', 2).first
        raise IOError, 'Invalid empty flow identity' if identifier.to_s.empty?

        { 'identifier' => identifier, 'type' => step['type'] }
      end

      def inspect_step(step, entry)
        return mark_unknown('flow_cycle', 'entry_point' => entry) if step['type'] == 'cycle'
        unless step['operations'].is_a?(Array)
          return mark_unknown('flow_operations_unavailable', 'entry_point' => entry)
        end

        FlowCalls.new(@budget).each_unknown(step.fetch('operations')) do |item|
          mark_unknown(item.fetch('kind'), item.merge('entry_point' => entry))
        end
      end

      def consume(key, reason)
        @budget[key] -= 1
        throw :flow_budget, reason if @budget[key].negative?
      end

      def mark_unknown(kind, fields = {})
        @partial = true
        @unknowns << @context.merge(fields).merge('kind' => kind)
      end

      def response(coverage)
        { 'flows' => @flows, 'unknowns' => @unknowns.uniq, 'coverage' => coverage }
      end
    end
  end
end
