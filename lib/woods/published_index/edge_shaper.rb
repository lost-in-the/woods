# frozen_string_literal: true

module Woods
  class PublishedIndex
    # Turns raw `dependency_graph.json` data into the flat, uniform edge shape
    # {PublishedIndex#edges} returns: `{ from:, to:, via:, through:,
    # disable_joins: }`.
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
      # @return [Array<Hash>] `{ from:, to:, via:, through:, disable_joins: }`
      def self.call(graph)
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
            disable_joins: raw['disable_joins'] == true }
        else
          { from: from, to: raw.to_s, via: nil, through: nil, disable_joins: false }
        end
      end

      private_class_method :variant_edges, :variant_records, :edge_hash
    end
  end
end
