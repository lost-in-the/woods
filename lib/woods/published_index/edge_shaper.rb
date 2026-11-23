# frozen_string_literal: true

module Woods
  class PublishedIndex
    # Turns raw `dependency_graph.json` data into the flat, uniform edge shape
    # {PublishedIndex#edges} returns: `{ from:, to:, via:, through:,
    # through_db:, disable_joins: }`.
    #
    # Pulled out of {PublishedIndex} itself because this walk is pure data
    # shaping with no dependency on the pinned generation or its retention
    # lock; keeping it separate is what lets the surrounding class stay under
    # `Metrics/ClassLength` without an exclude entry.
    module EdgeShaper
      # Every forward edge in the graph: primary nodes and variants alike. An
      # identifier shared by more than one type contributes one edge per
      # owning type, two edges are never folded into one just because they
      # look alike once reduced to this shape.
      #
      # @param graph [Hash] raw dependency graph data
      #   ({Woods::MCP::IndexReader#raw_graph_data})
      # @param via [String, nil] optional relationship label filter
      # @return [Array<Hash>] `{ from:, to:, via:, through:, through_db:, disable_joins: }`
      def self.call(graph, via: nil)
        return all_edges(graph) unless via

        edges = []
        each_owner(graph) do |from, list|
          list.each do |raw|
            edges << edge_hash(from, raw) if raw.is_a?(Hash) && raw['via'] == via
          end
        end
        edges
      end

      # Keep primary then variant encounter order without allocating edge hashes
      # for non-matching edges.
      #
      # @param graph [Hash] raw dependency graph data
      # @param target [String] target identifier
      # @param via [String] relationship label
      # @return [Array<String>] unique dependent identifiers
      def self.dependents(graph, target, via)
        sources = []
        each_owner(graph) do |from, list|
          sources << from if list.any? { |raw| raw.is_a?(Hash) && raw['target'] == target && raw['via'] == via }
        end
        sources.uniq
      end

      def self.each_owner(graph)
        (graph['edges'] || {}).each { |from, list| yield from, Array(list) }
        variant_records(graph).each { |record| yield record['identifier'], Array(record['edges']) }
      end

      def self.all_edges(graph)
        primary = (graph['edges'] || {}).flat_map { |from, list| Array(list).map { |raw| edge_hash(from, raw) } }
        primary + variant_edges(graph)
      end

      # Edges owned by a type recorded only in the graph's `variants` section:
      # an identifier that names units of more than one type keeps its other
      # types' out-edges there, since the primary `edges` map holds only one
      # type's edges per identifier.
      #
      # @param graph [Hash] raw dependency graph data
      # @return [Array<Hash>]
      def self.variant_edges(graph)
        variant_records(graph).flat_map do |record|
          Array(record['edges']).map { |raw| edge_hash(record['identifier'], raw) }
        end
      end

      # @param graph [Hash] raw dependency graph data
      # @return [Array<Hash>] entries from `variants` that name an identifier
      def self.variant_records(graph)
        Array(graph['variants']).select { |record| record.is_a?(Hash) && record['identifier'] }
      end

      # @param from [String]
      # @param raw [String, Hash] a bare target (pre-via graphs) or an edge hash
      # @return [Hash]
      def self.edge_hash(from, raw)
        if raw.is_a?(Hash)
          { from: from, to: raw['target'], via: raw['via'], through: raw['through'],
            through_db: raw['through_db'], disable_joins: raw['disable_joins'] == true }
        else
          { from: from, to: raw.to_s, via: nil, through: nil, through_db: nil, disable_joins: false }
        end
      end

      private_class_method :each_owner, :all_edges, :variant_edges, :variant_records, :edge_hash
    end
  end
end
