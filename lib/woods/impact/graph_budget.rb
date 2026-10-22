# frozen_string_literal: true

require_relative 'options'

module Woods
  module Impact
    # Shared endpoint budget for node visits and examined relationships.
    class GraphBudget
      # @param options [Options] validated graph work limits
      def initialize(options)
        @options = options.to_h
        @nodes = 0
        @examined = 0
      end

      # Charge one root, witness or related-unit visit before admitting it.
      # @return [void]
      def consume_node
        @nodes += 1
        throw :impact_budget, 'node_budget' if @nodes > @options.fetch('max_nodes')
      end

      # Charge one relationship before interpreting it or applying filters.
      # @return [void]
      def consume_edge
        @examined += 1
        throw :impact_budget, 'edge_budget' if @examined > @options.fetch('max_edges')
      end
    end
  end
end
