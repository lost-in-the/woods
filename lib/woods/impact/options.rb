# frozen_string_literal: true

module Woods
  module Impact
    # Validated finite query parameters, recorded verbatim after normalization.
    class Options
      BUDGETS = { max_nodes: [1000, 10_000], max_edges: [10_000, 100_000],
                  max_flow_documents: [100, 1000], max_flow_steps: [10_000, 100_000],
                  max_flow_operations: [10_000, 100_000], max_risk_records: [10_000, 100_000] }.freeze
      # @param depth [Integer] maximum reverse hops, 0..10
      # @param types [Array<String>, nil] actual source types allowed at every hop
      # @param via [Array<String>, nil] allowed relationship labels
      # @param max_nodes [Integer] root/witness visits per endpoint, 1..10000
      # @param max_edges [Integer] examined relationships per endpoint, 1..100000
      # @param budgets [Hash] optional node, edge, flow document, step and operation budgets
      def initialize(depth: 2, types: nil, via: nil, **budgets)
        raise ArgumentError, 'Unsupported impact parameter' unless (budgets.keys - BUDGETS.keys).empty?

        @data = { 'depth' => integer(depth, 0..10), 'types' => strings(types), 'via' => strings(via),
                  **BUDGETS.to_h { |key, (default, max)| [key.to_s, integer(budgets.fetch(key, default), 1..max)] } }
      end

      # @return [Hash] normalized parameters
      def to_h
        @data.dup
      end

      private

      def integer(value, range)
        unless value.is_a?(Integer) && range.cover?(value)
          raise ArgumentError, "Impact integer parameter outside #{range}"
        end

        value
      end

      def strings(value)
        return if value.nil?
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
          raise ArgumentError, 'Impact filters must be arrays of nonempty strings'
        end

        value.uniq.sort
      end
    end
  end
end
