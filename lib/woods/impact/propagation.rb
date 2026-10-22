# frozen_string_literal: true

require 'set'
require_relative 'options'
require_relative 'reverse_edges'

module Woods
  module Impact
    # Bounded typed reverse traversal with one shortest witness per root/affected
    # identity. Each instance consumes exactly one generation's published facts.
    class Propagation
      # @param graph [Hash] retained graph
      # @param units [Hash] retained typed units
      # @param generation [Integer]
      # @param endpoint [String] from or to
      # @param options [Options]
      def initialize(graph, units, generation:, endpoint:, options:)
        @edges = ReverseEdges.new(graph, units)
        @context = { 'generation' => generation, 'endpoint' => endpoint }
        @options = options.to_h
        @affected = {}
        @unknowns = []
        @nodes = 0
        @examined = 0
      end

      # @param roots [Array<Array(String, String)>] exact changed identities
      # @return [Hash] affected, unknowns, coverage
      def call(roots)
        @roots = roots.to_set
        reason = catch(:impact_budget) do
          roots.sort.each { |root| walk(root) }
          nil
        end
        unknown(reason) if reason
        { 'affected' => @affected.sort.map(&:last), 'unknowns' => @unknowns.uniq,
          'coverage' => @unknowns.empty? ? 'bounded' : 'partial' }
      end

      private

      def walk(root)
        consume_node
        @queue = [[root, []]]
        @visited = Set[root]
        cursor = 0
        while cursor < @queue.size
          identity, path = @queue[cursor]
          cursor += 1
          next if path.size >= @options.fetch('depth')

          @edges.records(identity).each { |record| visit(root, identity, path, record) }
        end
      end

      def visit(root, identity, path, record)
        @examined += 1
        throw :impact_budget, 'edge_budget' if @examined > @options.fetch('max_edges')
        resolved = @edges.resolve(identity, record)
        if resolved.is_a?(String)
          return unknown(resolved, identity, 'edge' => record.slice('source', 'source_type', 'via', 'type'))
        end
        return unless resolved

        source, edge = resolved
        return unless allowed?(source, edge)

        consume_node
        @visited.add(source)
        next_path = path + [edge]
        @queue << [source, next_path]
        record_affected(source, root, next_path) unless @roots.include?(source)
      end

      def allowed?(source, edge)
        return false if @visited.include?(source)
        return false if @options['types'] && !@options['types'].include?(source.last)

        @options['via'].nil? || @options['via'].include?(edge['via'])
      end

      def record_affected(identity, root, path)
        weight, reason = @edges.weight(identity)
        unknown(reason, identity) if reason
        entry = (@affected[identity] ||= typed(identity).merge(@context).merge(
          'distance' => path.size, 'weight' => weight, 'paths' => []
        ))
        entry['distance'] = [entry['distance'], path.size].min
        entry['paths'] << @context.merge('root' => typed(root), 'edges' => path)
      end

      def consume_node
        @nodes += 1
        throw :impact_budget, 'node_budget' if @nodes > @options.fetch('max_nodes')
      end

      def typed(identity)
        { 'identifier' => identity.first, 'type' => identity.last }
      end

      def unknown(kind, identity = nil, fields = {})
        entry = @context.merge(fields).merge('kind' => kind)
        entry.merge!(typed(identity)) if identity
        @unknowns << entry
      end
    end
  end
end
