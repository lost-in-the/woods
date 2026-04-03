# frozen_string_literal: true

require_relative 'node_builder'
require_relative 'edge_builder'

module Woods
  module SvelteFlow
    # Orchestrates conversion of Woods extraction data into Svelte Flow format.
    #
    # Takes a DependencyGraph, GraphAnalyzer, and optional flow documents,
    # and produces Svelte Flow-compatible hashes with nodes and edges arrays.
    # Does NOT perform I/O — callers handle reading/writing.
    #
    # @example
    #   transformer = Transformer.new(graph: graph, analyzer: analyzer)
    #   data = transformer.dependency_graph_data
    #   # => { "nodes" => [...], "edges" => [...] }
    #
    class Transformer # rubocop:disable Metrics/ClassLength
      # @param graph [DependencyGraph] The dependency graph
      # @param analyzer [GraphAnalyzer] Graph analyzer for structural enrichment
      def initialize(graph:, analyzer:)
        @graph = graph
        @analyzer = analyzer
      end

      # Convert the full dependency graph into Svelte Flow format.
      #
      # @return [Hash] { "nodes" => Array, "edges" => Array }
      def dependency_graph_data # rubocop:disable Metrics/MethodLength
        graph_data = @graph.to_h
        nodes = graph_data[:nodes] || graph_data['nodes'] || {}
        edges = graph_data[:edges] || graph_data['edges'] || {}
        pagerank_scores = @graph.pagerank

        analysis = build_analysis
        cycle_edges = build_cycle_edge_set(analysis[:cycles] || [])

        positions = {}

        node_builder = NodeBuilder.new(
          nodes: nodes,
          positions: positions,
          pagerank: pagerank_scores,
          analysis: analysis
        )

        valid_ids = Set.new(nodes.keys)
        edge_builder = EdgeBuilder.new(
          edges: edges,
          valid_node_ids: valid_ids,
          cycle_edges: cycle_edges
        )

        {
          'nodes' => node_builder.build,
          'edges' => edge_builder.build
        }
      end

      # Convert a flow document into Svelte Flow format.
      #
      # @param flow_data [Hash] Serialized FlowDocument (from FlowDocument#to_h or JSON)
      # @return [Hash] { "nodes" => Array, "edges" => Array, "metadata" => Hash }
      def flow_data(flow_data) # rubocop:disable Metrics
        steps = flow_data[:steps] || flow_data['steps'] || []

        flow_nodes = []
        seen = Set.new
        step_index = 0

        steps.each do |step|
          unit = step[:unit] || step['unit']
          next unless unit
          next if seen.include?(unit)

          seen.add(unit)
          step_type = step[:type] || step['type']
          operations = step[:operations] || step['operations'] || []

          flow_nodes << {
            'id' => unit,
            'type' => 'flow_step',
            'position' => { 'x' => 0, 'y' => step_index * 150 },
            'data' => {
              'label' => unit,
              'stepType' => step_type.to_s,
              'filePath' => step[:file_path] || step['file_path'],
              'operationCount' => operations.size,
              'operations' => summarize_operations(operations)
            }
          }
          step_index += 1
        end

        flow_edges = EdgeBuilder.flow_edges(steps)

        {
          'nodes' => flow_nodes,
          'edges' => flow_edges,
          'metadata' => {
            'entryPoint' => flow_data[:entry_point] || flow_data['entry_point'],
            'route' => flow_data[:route] || flow_data['route'],
            'maxDepth' => flow_data[:max_depth] || flow_data['max_depth']
          }
        }
      end

      # Convert domain clusters into Svelte Flow format.
      #
      # @return [Hash] { "nodes" => Array, "edges" => Array, "clusters" => Array }
      def domain_cluster_data # rubocop:disable Metrics
        clusters = @analyzer.domain_clusters
        return { 'nodes' => [], 'edges' => [], 'clusters' => [] } if clusters.empty?

        graph_data = @graph.to_h
        edges = graph_data[:edges] || graph_data['edges'] || {}
        nodes = graph_data[:nodes] || graph_data['nodes'] || {}
        pagerank_scores = @graph.pagerank

        analysis = build_analysis

        # Build nodes only for members that appear in clusters
        cluster_member_ids = clusters.flat_map { |c| c[:members] || c['members'] || [] }
        cluster_nodes = nodes.slice(*cluster_member_ids)

        node_builder = NodeBuilder.new(
          nodes: cluster_nodes,
          positions: {},
          pagerank: pagerank_scores,
          analysis: analysis
        )

        # Collect all boundary edges across clusters
        all_boundary_edges = clusters.flat_map { |c| c[:boundary_edges] || c['boundary_edges'] || [] }
        valid_ids = Set.new(cluster_member_ids)

        boundary = EdgeBuilder.boundary_edges(all_boundary_edges, valid_node_ids: valid_ids)

        # Also include intra-cluster dependency edges
        intra_edges = cluster_member_ids.each_with_object({}) do |id, h|
          targets = (edges[id] || []) & cluster_member_ids
          h[id] = targets unless targets.empty?
        end
        intra_edge_builder = EdgeBuilder.new(edges: intra_edges, valid_node_ids: valid_ids)

        cluster_summaries = clusters.map do |c|
          {
            'name' => c[:name] || c['name'],
            'hub' => c[:hub] || c['hub'],
            'memberCount' => c[:member_count] || c['member_count'],
            'entryPoints' => c[:entry_points] || c['entry_points'] || [],
            'types' => c[:types] || c['types'] || {}
          }
        end

        {
          'nodes' => node_builder.build,
          'edges' => intra_edge_builder.build + boundary,
          'clusters' => cluster_summaries
        }
      end

      # Export all visualization types in a single wrapper.
      #
      # @param flow_documents [Array<Hash>] Optional flow documents to include
      # @return [Hash] Combined export with dependency_graph, flows, and clusters
      def full_export(flow_documents: [])
        result = {
          'dependency_graph' => dependency_graph_data,
          'domain_clusters' => domain_cluster_data,
          'flows' => {}
        }

        flow_documents.each do |doc|
          entry = doc[:entry_point] || doc['entry_point']
          result['flows'][entry] = flow_data(doc) if entry
        end

        result
      end

      private

      # Build analysis data from the GraphAnalyzer.
      #
      # @return [Hash] Analysis results
      def build_analysis
        @build_analysis ||= {
          hubs: @analyzer.hubs,
          bridges: @analyzer.bridges(limit: 20),
          orphans: @analyzer.orphans,
          cycles: @analyzer.cycles
        }
      end

      # Build a set of cycle edge pairs for marking in the edge builder.
      #
      # @param cycles [Array<Array<String>>] Cycle paths from GraphAnalyzer
      # @return [Set<Array<String>>] Set of [source, target] pairs
      def build_cycle_edge_set(cycles)
        cycle_edges = Set.new
        cycles.each do |cycle|
          cycle.each_cons(2) { |a, b| cycle_edges.add([a, b]) }
        end
        cycle_edges
      end

      # Summarize operations for a flow step node's data.
      #
      # @param operations [Array<Hash>] Operations from a flow step
      # @return [Array<Hash>] Simplified operation summaries
      def summarize_operations(operations)
        operations.map do |op|
          type = (op[:type] || op['type']).to_s
          {
            'type' => type,
            'target' => op[:target] || op['target'],
            'method' => op[:method] || op['method'],
            'line' => op[:line] || op['line']
          }
        end
      end
    end
  end
end
