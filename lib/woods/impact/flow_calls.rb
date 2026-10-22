# frozen_string_literal: true

module Woods
  module Impact
    # Bounded operation walk. Unit membership cannot prove method-call expansion.
    class FlowCalls
      # @param budget [Hash] shared mutable remaining counts for one endpoint
      def initialize(budget)
        @budget = budget
      end

      # @param operations [Array<Hash>]
      # @yieldparam unknown [Hash] yielded immediately, preserving evidence on truncation
      # @return [void]
      def each_unknown(operations)
        raise IOError, 'Invalid flow operations' unless operations.is_a?(Array)

        queue = operations.dup
        cursor = 0
        while cursor < queue.size
          consume
          operation = queue[cursor]
          cursor += 1
          raise IOError, 'Invalid flow operation' unless operation.is_a?(Hash)

          yield call_unknown(operation) if %w[call async].include?(operation['type'])
          nested_operations(operation).each { |nested| queue.concat(nested) }
        end
      end

      private

      def consume
        @budget['max_flow_operations'] -= 1
        throw :flow_budget, 'flow_operation_budget' if @budget['max_flow_operations'].negative?
      end

      def nested_operations(operation)
        %w[nested then_ops else_ops].filter_map do |key|
          next unless operation.key?(key)
          raise IOError, 'Invalid nested flow operations' unless operation[key].is_a?(Array)

          operation[key]
        end
      end

      def call_unknown(operation)
        kind = operation['target'] ? 'unproven_call_expansion' : 'receiverless_call'
        operation.slice('target', 'method', 'ambiguous_candidates').merge('kind' => kind)
      end
    end
  end
end
