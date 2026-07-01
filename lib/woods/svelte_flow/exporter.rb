# frozen_string_literal: true

require 'json'
require 'set'
require 'fileutils'

require_relative 'transformer'
require_relative 'subgraph_scoper'
require_relative 'source_links'
require_relative 'standalone_renderer'
require_relative '../dependency_graph'
require_relative '../graph_analyzer'
require_relative '../filename_utils'

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
      include FilenameUtils

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
        unit_metadata = load_unit_metadata
        transformer = Transformer.new(graph: graph, analyzer: analyzer, unit_metadata: unit_metadata)

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

      # Export a query-scoped subgraph as a single self-contained HTML file.
      # The scoped graph and per-unit sources are inlined, so the file opens
      # over file:// with no server — the offline mirror of the `?nodes=` URL.
      #
      # @param nodes [Array<String>] Seed identifiers to render
      # @param depth [Integer] Extra BFS hops around the set
      # @param via [Array<String>, nil] Relationship filter
      # @param output_path [String, nil] Destination (defaults under output_dir)
      # @return [Hash] { path:, nodes:, edges:, dropped: }
      # @raise [Woods::ExtractionError] if none of the requested nodes exist
      def export_standalone(nodes:, depth: 0, via: nil, output_path: nil)
        transformer = build_transformer
        seeds, known = resolve_seeds(transformer, nodes)
        raise Woods::ExtractionError, "None of the requested nodes exist: #{seeds.join(', ')}" if known.empty?

        payload = SubgraphScoper.new(transformer).payload(seeds: known, depth: depth, via_set: build_via_set(via))
        html = render_standalone(transformer, payload, known)
        path = write_standalone(html, output_path, known)

        { path: path, nodes: payload['nodes'].size, edges: payload['edges'].size, dropped: seeds - known }
      end

      private

      # Normalize seed identifiers and split into known vs unknown.
      #
      # @return [Array(Array<String>, Array<String>)] [seeds, known]
      def resolve_seeds(transformer, nodes)
        seeds = Array(nodes).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        known = seeds.select { |id| transformer.graph.node_exists?(id) }
        [seeds, known]
      end

      # Render the standalone HTML for a scoped payload.
      #
      # @return [String]
      def render_standalone(transformer, payload, known)
        sources = build_sources(transformer, payload['nodes'].map { |n| n['id'] })
        StandaloneRenderer.new.render(graph: payload, sources: sources, title: "Woods — #{known.join(', ')}")
      end

      # Write the HTML file, returning its path.
      #
      # @return [String]
      def write_standalone(html, output_path, known)
        base = safe_filename(known.first).sub(/\.json\z/, '')
        path = output_path || File.join(@output_dir, "subgraph-#{base}.html")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, html)
        path
      end

      # @param via [Array<String>, nil]
      # @return [Set<Symbol>, nil]
      def build_via_set(via)
        labels = Array(via).map(&:to_s).map(&:strip).reject(&:empty?)
        labels.empty? ? nil : Set.new(labels.map(&:to_sym))
      end

      # Build the inlined per-unit source map for the scoped nodes.
      #
      # @param transformer [Transformer]
      # @param node_ids [Array<String>]
      # @return [Hash<String, Hash>]
      def build_sources(transformer, node_ids)
        repo_url = Woods.configuration.svelte_flow_repo_url
        git_sha = manifest_git_sha

        node_ids.each_with_object({}) do |id, acc|
          unit = transformer.unit_metadata[id]
          next unless unit

          file_path = unit['file_path']
          acc[id] = {
            'identifier' => id,
            'filePath' => file_path,
            'sourceCode' => unit['source_code'],
            'blobUrl' => SourceLinks.github_blob_url(file_path, repo_url: repo_url, git_sha: git_sha)
          }
        end
      end

      # Read the extraction's git SHA from the manifest, if present.
      #
      # @return [String, nil]
      def manifest_git_sha
        manifest = JSON.parse(File.read(File.join(@index_dir, 'manifest.json')))
        manifest['git_sha']
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

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
        unit_metadata = load_unit_metadata
        Transformer.new(graph: graph, analyzer: analyzer, unit_metadata: unit_metadata)
      end

      # Load per-unit metadata from extraction output type directories.
      #
      # Scans each type subdirectory for individual unit JSON files (not _index.json)
      # and extracts identifier + metadata for NodeBuilder enrichment.
      #
      # @return [Hash<String, Hash>] identifier => unit data hash
      def load_unit_metadata # rubocop:disable Metrics
        metadata = {}

        Dir.glob(File.join(@index_dir, '*')).each do |type_dir|
          next unless File.directory?(type_dir)
          next if File.basename(type_dir) == 'svelte_flow'
          next if File.basename(type_dir) == 'flows'

          Dir.glob(File.join(type_dir, '*.json')).each do |unit_file|
            next if File.basename(unit_file) == '_index.json'

            unit_data = JSON.parse(File.read(unit_file))
            identifier = unit_data['identifier']
            next unless identifier

            metadata[identifier.to_s] = unit_data
          rescue JSON::ParserError => e
            warn "Woods::SvelteFlow::Exporter: skipping malformed JSON at #{unit_file}: #{e.message}"
            next
          end
        end

        metadata
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
