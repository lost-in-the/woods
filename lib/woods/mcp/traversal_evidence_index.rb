# frozen_string_literal: true

require 'set'

module Woods
  module MCP
    # A generation-scoped view retaining typed edge ownership. Only node/variant
    # indexes are prepared eagerly; relationship arrays remain lazy and every
    # examined relationship consumes the caller's work budget.
    class TraversalEvidenceIndex
      ATTRIBUTES = %w[via through through_db disable_joins].freeze

      def initialize(graph)
        @graph = graph
        @nodes = graph.fetch('nodes', {})
        @variants = Array(graph['variants']).group_by { |record| record['identifier'] }
        @types = @nodes.transform_values { |node| [node['type']].compact }
        @variants.each do |identifier, records|
          @types[identifier] = ((@types[identifier] || []) + records.map { |record| record['type'] }).compact.uniq.sort
        end
        @types.transform_values!(&:freeze).freeze
        @multi_database = @nodes.values.filter_map { |node| node['database'] }.uniq.size > 1
      end

      def include?(identifier)
        @nodes.key?(identifier)
      end

      def types(identifier)
        @types.fetch(identifier, [])
      end

      def identity(identifier)
        candidates = types(identifier)
        return { identifier: identifier, type: candidates.first } if candidates.size == 1

        { identifier: identifier, type: nil, candidate_types: candidates,
          resolution: candidates.empty? ? 'unresolved' : 'ambiguous' }
      end

      def node(identifier, depth)
        metadata = @nodes[identifier]
        result = { type: metadata&.dig('type'), depth: depth, deps: [] }
        result[:types] = types(identifier) if types(identifier).size > 1
        result[:database] = metadata&.dig('database') if @multi_database
        result
      end

      def each_edge(identifier, direction, budget, &block)
        if direction == :forward
          each_forward(identifier, budget, &block)
        elsif @graph.key?('reverse_via')
          each_reverse_record(identifier, budget, &block)
        else
          each_legacy_reverse(identifier, budget, &block)
        end
      end

      private

      def each_forward(identifier, budget, &block)
        primary = @nodes[identifier]
        each_owned_edge(identifier, primary && primary['type'], @graph.fetch('edges', {})[identifier], budget, &block)
        (@variants[identifier] || []).each do |record|
          each_owned_edge(identifier, record['type'], record['edges'], budget, &block)
        end
      end

      def each_owned_edge(identifier, type, edges, budget)
        (edges || []).each do |stored|
          budget.consume_edge
          stored = { 'target' => stored } unless stored.is_a?(Hash)
          yield record(identifier, type, stored.fetch('target'), stored)
        end
      end

      def each_reverse_record(identifier, budget)
        (@graph.fetch('reverse_via')[identifier] || []).each do |stored|
          budget.consume_edge
          yield record(stored.fetch('source'), stored.fetch('source_type'), identifier, stored)
        end
      end

      def each_legacy_reverse(identifier, budget)
        (@graph.fetch('reverse', {})[identifier] || []).each do |source|
          budget.consume_edge
          each_forward(source, budget) do |edge|
            yield edge if edge[:target][:identifier] == identifier
          end
        end
      end

      def record(source, type, target, stored)
        result = { source: { identifier: source, type: type }, target: identity(target) }
        ATTRIBUTES.each { |attribute| result[attribute.to_sym] = stored[attribute] }
        result
      end
    end
  end
end
