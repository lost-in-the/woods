# frozen_string_literal: true

require 'set'
require_relative 'node_builder'
require_relative 'edge_builder'
require_relative 'association_edge_builder'
require_relative 'edge_data'
require_relative 'neighborhood'

module Woods
  module SvelteFlow
    # Scopes a dependency graph to a set of seed nodes and renders it as a
    # Svelte Flow payload. This is the single scoping core shared by the live
    # HTTP endpoints (RackMiddleware) and the offline exporter, so the two can
    # never drift.
    #
    # @example
    #   scoper = SubgraphScoper.new(transformer)
    #   scoper.payload(seeds: %w[Order Account], depth: 1, via_set: Set[:belongs_to])
    #   # => { "nodes" => [...], "edges" => [...], "highest_pagerank" => "Order" }
    #
    class SubgraphScoper
      # @param transformer [Transformer] Provides graph, analyzer, and unit_metadata
      def initialize(transformer)
        @transformer = transformer
      end

      # Expand a seed set by `depth` BFS hops and render the induced subgraph.
      #
      # @param seeds [String, Array<String>, Set<String>] Seed identifier(s)
      # @param depth [Integer] Hops to expand (0 = seeds only)
      # @param via_set [Set<Symbol>, nil] Optional relationship filter
      # @return [Hash] { 'nodes' =>, 'edges' =>, 'highest_pagerank' => }
      def payload(seeds:, depth: 0, via_set: nil)
        adjacency = graph_adjacency
        visited = Neighborhood.collect(seeds, depth, adjacency, via_set: via_set)
        build_payload(visited, adjacency, via_set: via_set)
      end

      private

      # The graph's adjacency maps, bundled so they travel together.
      # `DependencyGraph#to_h` always emits symbol keys.
      # @return [Hash] { nodes:, edges:, reverse: }
      def graph_adjacency
        data = @transformer.graph.to_h
        { nodes: data[:nodes] || {}, edges: data[:edges] || {}, reverse: data[:reverse] || {} }
      end

      # Build the Svelte Flow payload for a resolved set of visited node IDs.
      #
      # Model↔model relationships are emitted as ERD-style association edges
      # (type "association", FK/PK column handles, macro in data.via) via
      # AssociationEdgeBuilder — same as the full-graph path — so the frontend
      # can anchor them to columns and draw cardinality markers. The generic
      # EdgeBuilder skips pairs covered by an association edge to avoid
      # duplicates.
      #
      # @return [Hash]
      def build_payload(visited, adjacency, via_set: nil)
        scoped_nodes, scoped_forward, scoped_reverse = build_scoped_graph(visited, adjacency, via_set: via_set)

        pagerank_scores = @transformer.graph.pagerank
        cycle_edges = cycle_edges_for(visited)
        association_edges = build_association_edges(visited, cycle_edges, via_set)

        node_builder = NodeBuilder.new(
          nodes: scoped_nodes, positions: {}, pagerank: pagerank_scores,
          analysis: scoped_analysis,
          unit_metadata: @transformer.unit_metadata || {},
          forward_edges: scoped_forward, reverse_edges: scoped_reverse
        )
        edge_builder = EdgeBuilder.new(
          edges: scoped_forward, valid_node_ids: visited,
          cycle_edges: cycle_edges,
          exclude_pairs: association_pair_exclusions(association_edges)
        )

        {
          'nodes' => node_builder.build,
          'edges' => association_edges + edge_builder.build,
          'highest_pagerank' => pagerank_scores.max_by { |_k, v| v }&.first
        }
      end

      # ERD-style association edges among the visited units. Metadata is sliced
      # to the visited set first, so AssociationEdgeBuilder's own target-existence
      # check keeps every edge inside the subgraph.
      #
      # @param visited [Set<String>]
      # @param cycle_edges [Set<Array<String>>]
      # @param via_set [Set<Symbol>, nil] Optional relationship filter
      # @return [Array<Hash>]
      def build_association_edges(visited, cycle_edges, via_set)
        metadata = @transformer.unit_metadata || {}
        scoped = visited.each_with_object({}) { |id, acc| acc[id] = metadata[id] if metadata.key?(id) }
        edges = AssociationEdgeBuilder.new(unit_metadata: scoped, cycle_edges: cycle_edges).build
        return edges unless via_set

        edges.select { |edge| via_set.include?(edge['data']['via']&.to_sym) }
      end

      # Pairs already rendered as association edges, in both directions —
      # Rails associations are declared bidirectionally, so the graph usually
      # carries a directed edge each way for one relationship. Pairs with no
      # association metadata (e.g. plain code references between models) are
      # NOT excluded and still render as generic edges.
      #
      # @param association_edges [Array<Hash>]
      # @return [Set<Array<String>>]
      def association_pair_exclusions(association_edges)
        association_edges.each_with_object(Set.new) do |edge, pairs|
          pairs.add([edge['source'], edge['target']])
          pairs.add([edge['target'], edge['source']])
        end
      end

      # Scope nodes and edges to the visited set.
      # @return [Array(Hash, Hash, Hash)] scoped_nodes, scoped_forward, scoped_reverse
      def build_scoped_graph(visited, adjacency, via_set: nil)
        nodes = adjacency[:nodes]
        scoped_nodes = {}
        scoped_forward = {}
        scoped_reverse = {}

        visited.each do |source|
          scoped_nodes[source] = nodes[source] if nodes.key?(source)

          fwd = forward_in_scope(adjacency[:edges][source], visited, via_set)
          scoped_forward[source] = fwd unless fwd.empty?

          rev = (adjacency[:reverse][source] || []).select { |target| visited.include?(target) }
          scoped_reverse[source] = Set.new(rev) unless rev.empty?
        end

        [scoped_nodes, scoped_forward, scoped_reverse]
      end

      # Forward { target:, via: } entries kept in scope: target in `visited`, and
      # (if filtering) relationship in `via_set`. Kept as hashes so EdgeBuilder
      # can label the rendered edges.
      #
      # @return [Array]
      def forward_in_scope(entries, visited, via_set)
        (entries || []).select do |entry|
          visited.include?(EdgeData.target(entry)) && (via_set.nil? || via_set.include?(EdgeData.via(entry)))
        end
      end

      # Structural annotations for NodeBuilder, guarded so a missing analyzer
      # method degrades to an empty list rather than raising.
      #
      # @return [Hash]
      def scoped_analysis
        {
          hubs: safe_analysis { @transformer.analyzer.hubs(limit: 20) },
          bridges: safe_analysis { @transformer.analyzer.bridges(limit: 20) },
          orphans: safe_analysis { @transformer.analyzer.orphans }
        }
      end

      # @return [Array] The block's result, or [] on any error.
      def safe_analysis
        yield
      rescue StandardError
        []
      end

      # Cycle edge pairs restricted to the visited set.
      #
      # @return [Set<Array<String>>]
      def cycle_edges_for(visited)
        cycle_edges = Set.new
        @transformer.analyzer.cycles.each do |cycle|
          cycle.each_cons(2) do |a, b|
            cycle_edges.add([a, b]) if visited.include?(a) && visited.include?(b)
          end
        end
        cycle_edges
      rescue StandardError
        Set.new
      end
    end
  end
end
