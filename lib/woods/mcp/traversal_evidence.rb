# frozen_string_literal: true

require_relative 'traversal_evidence_index'
require_relative 'traversal_evidence_page'

module Woods
  module MCP
    # Per-query identifier-level BFS with truthful typed records and a shared
    # predecessor forest. Ambiguous endpoints never become a claimed typed path.
    class TraversalEvidence
      class Budget
        attr_reader :data

        def initialize(max_nodes, max_edges)
          @data = { max_nodes: max_nodes.to_i.clamp(1, 10_000), max_edges: max_edges.to_i.clamp(1, 100_000),
                    visited_nodes: 1, visited_edges: 0 }
        end

        def consume_node
          throw :traversal_budget, 'node_budget' if data[:visited_nodes] >= data[:max_nodes]

          data[:visited_nodes] += 1
        end

        def consume_edge
          throw :traversal_budget, 'edge_budget' if data[:visited_edges] >= data[:max_edges]

          data[:visited_edges] += 1
        end
      end

      def initialize(index)
        @index = index
      end

      def call(identifier, depth: 2, direction: :forward, types: nil, via: nil, max_nodes: 1000, max_edges: 10_000)
        return { root: identifier, found: false, nodes: {} } unless @index.include?(identifier)

        prepare(identifier, depth, direction, types, via, max_nodes, max_edges)
        cursor = 0
        while cursor < @queue.size
          current, level = @queue[cursor]
          cursor += 1
          entry = @index.node(current, level)
          @nodes[current] = entry
          next if @partial_reason || level >= @depth

          @partial_reason = catch(:traversal_budget) do
            @index.each_edge(current, @direction, @budget) { |edge| visit(current, level, entry, edge) }
            nil
          end
        end
        response(identifier)
      end

      private

      def prepare(identifier, depth, direction, types, via, max_nodes, max_edges)
        @depth = depth
        @direction = direction
        @types = types&.to_set
        @via = via&.to_set
        @budget = Budget.new(max_nodes, max_edges)
        @queue = [[identifier, 0]]
        @nodes = {}
        @neighbors = Hash.new { |hash, key| hash[key] = Set.new }
        @edges = {}
        @edge_ids = {}
        @partial_reason = nil
        @witnesses = { identifier => { parent: nil, edge_id: nil, impact: 'root',
                                       typed_path_complete: @index.types(identifier).size == 1 } }
      end

      def visit(current, level, entry, edge)
        return if @via && !@via.include?(edge[:via])

        neighbor = edge.fetch(@direction == :forward ? :target : :source).fetch(:identifier)
        return if @types && @index.types(neighbor).none? { |type| @types.include?(type) }

        unless @witnesses.key?(neighbor)
          @budget.consume_node
          @queue << [neighbor, level + 1]
          @witnesses[neighbor] = witness(current, level, edge)
        end
        edge_id(edge)
        entry[:deps] << neighbor if @neighbors[current].add?(neighbor)
      end

      def witness(current, level, edge)
        complete = @witnesses.fetch(current)[:typed_path_complete] && !edge[:target][:type].nil? &&
                   @index.types(edge[:source][:identifier]).size == 1
        { parent: current, edge_id: edge_id(edge), impact: level.zero? ? 'direct' : 'transitive',
          typed_path_complete: complete }
      end

      def edge_id(edge)
        @edge_ids[edge] ||= begin
          id = "e#{@edges.size}"
          @edges[id] = edge
          id
        end
      end

      def response(identifier)
        result = { root: identifier, found: true, nodes: @nodes,
                   explanation: { direction: @direction.to_s, root: @index.identity(identifier),
                                  edges: @edges, witnesses: @witnesses } }
        result.merge!(partial: true, partial_reason: @partial_reason, traversal_budget: @budget.data) if @partial_reason
        result
      end
    end
  end
end
