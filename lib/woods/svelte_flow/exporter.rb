# frozen_string_literal: true

require 'json'
require 'fileutils'

require_relative 'transformer'
require_relative '../dependency_graph'
require_relative '../graph_analyzer'

module Woods
  module SvelteFlow
    # Reads Woods extraction output from disk and writes Svelte Flow JSON files.
    #
    # Follows the same export pipeline pattern as Notion::Exporter and
    # Unblocked::Exporter: reads via IndexReader, transforms, writes output.
    #
    # @example
    #   exporter = Exporter.new(index_dir: "tmp/woods")
    #   stats = exporter.export_all
    #   # => { nodes: 42, edges: 87, flows: 5, output_dir: "tmp/woods/svelte_flow" }
    #
    class Exporter # rubocop:disable Metrics/ClassLength
      # @param index_dir [String] Path to Woods extraction output directory
      # @param output_dir [String, nil] Output directory (defaults to index_dir/svelte_flow)
      def initialize(index_dir:, output_dir: nil)
        @index_dir = index_dir
        @output_dir = output_dir || File.join(index_dir, 'svelte_flow')

        validate_index_dir!
      end

      # Export all visualization data: dependency graph, domain clusters, and flows.
      #
      # @return [Hash] Export statistics
      def export_all # rubocop:disable Metrics/MethodLength
        graph = load_graph
        analyzer = GraphAnalyzer.new(graph)
        transformer = Transformer.new(graph: graph, analyzer: analyzer)

        FileUtils.mkdir_p(@output_dir)

        graph_stats = export_dependency_graph(transformer)
        cluster_stats = export_domain_clusters(transformer)
        flow_stats = export_flows(transformer)

        manifest = {
          'generated_at' => Time.now.iso8601,
          'node_count' => graph_stats[:node_count],
          'edge_count' => graph_stats[:edge_count],
          'cluster_count' => cluster_stats[:cluster_count],
          'flow_count' => flow_stats[:flow_count],
          'index_dir' => @index_dir
        }
        write_json('manifest.json', manifest)

        {
          nodes: graph_stats[:node_count],
          edges: graph_stats[:edge_count],
          clusters: cluster_stats[:cluster_count],
          flows: flow_stats[:flow_count],
          output_dir: @output_dir
        }
      end

      # Export only the dependency graph visualization.
      #
      # @param transformer [Transformer, nil] Pre-built transformer (optional)
      # @return [Hash] { node_count:, edge_count: }
      def export_dependency_graph(transformer = nil)
        transformer ||= build_transformer
        data = transformer.dependency_graph_data

        write_json('dependency_graph.json', data)

        {
          node_count: data['nodes'].size,
          edge_count: data['edges'].size
        }
      end

      # Export only the domain cluster visualization.
      #
      # @param transformer [Transformer, nil] Pre-built transformer (optional)
      # @return [Hash] { cluster_count: }
      def export_domain_clusters(transformer = nil)
        transformer ||= build_transformer
        data = transformer.domain_cluster_data

        write_json('domain_clusters.json', data)

        { cluster_count: (data['clusters'] || []).size }
      end

      # Export flow visualizations for all precomputed flows.
      #
      # @param transformer [Transformer, nil] Pre-built transformer (optional)
      # @return [Hash] { flow_count: }
      def export_flows(transformer = nil)
        transformer ||= build_transformer
        flow_index = load_flow_index
        return { flow_count: 0 } if flow_index.empty?

        flows_dir = File.join(@output_dir, 'flows')
        FileUtils.mkdir_p(flows_dir)

        flow_count = 0
        flow_manifest = {}

        flow_index.each do |entry_point, flow_path|
          flow_doc = load_flow_document(flow_path)
          next unless flow_doc

          svelte_data = transformer.flow_data(flow_doc)
          filename = safe_filename(entry_point)
          write_json(File.join('flows', filename), svelte_data)

          flow_manifest[entry_point] = filename
          flow_count += 1
        end

        write_json(File.join('flows', 'flow_index.json'), flow_manifest)

        { flow_count: flow_count }
      end

      private

      # Validate that the index directory exists and contains a manifest.
      #
      # @raise [Woods::ExtractionError] if index dir is invalid
      def validate_index_dir!
        manifest_path = File.join(@index_dir, 'manifest.json')
        return if File.exist?(manifest_path)

        raise Woods::ExtractionError,
              "No extraction output found at #{@index_dir}. Run `rake woods:extract` first."
      end

      # Load the dependency graph from disk.
      #
      # @return [DependencyGraph]
      def load_graph
        graph_path = File.join(@index_dir, 'dependency_graph.json')
        data = JSON.parse(File.read(graph_path))
        DependencyGraph.from_h(data)
      end

      # Build a transformer from disk data.
      #
      # @return [Transformer]
      def build_transformer
        graph = load_graph
        analyzer = GraphAnalyzer.new(graph)
        Transformer.new(graph: graph, analyzer: analyzer)
      end

      # Load the flow index mapping entry points to flow file paths.
      #
      # @return [Hash<String, String>]
      def load_flow_index
        index_path = File.join(@index_dir, 'flows', 'flow_index.json')
        return {} unless File.exist?(index_path)

        JSON.parse(File.read(index_path))
      end

      # Load a single flow document from disk.
      #
      # @param path [String] Path to the flow document JSON
      # @return [Hash, nil]
      def load_flow_document(path)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      # Generate a collision-safe filename from an identifier.
      #
      # @param identifier [String] Entry point identifier
      # @return [String] Safe filename with .json extension
      def safe_filename(identifier)
        "#{identifier.gsub('::', '__').gsub('#', '_')}.json"
      end

      # Write JSON data to a file in the output directory.
      #
      # @param relative_path [String] Path relative to output_dir
      # @param data [Hash, Array] Data to serialize
      def write_json(relative_path, data)
        path = File.join(@output_dir, relative_path)
        File.write(path, JSON.pretty_generate(data))
      end
    end
  end
end
