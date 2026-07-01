# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'transformer'
require_relative 'edge_data'
require_relative '../dependency_graph'
require_relative '../graph_analyzer'

module Woods
  module SvelteFlow
    # Rack middleware that serves the Svelte Flow visualization page and JSON API.
    #
    # Mounts at a configurable path (default: '/woods/visualize') and serves:
    # - GET /              => HTML page with embedded Svelte Flow app
    # - GET /api/graph     => Dependency graph as Svelte Flow JSON
    # - GET /api/clusters  => Domain clusters as Svelte Flow JSON
    # - GET /api/flows     => Flow index (entry points list)
    # - GET /api/flows/:id => Individual flow as Svelte Flow JSON
    # - GET /assets/*      => Static JS/CSS assets
    #
    # Data is lazy-loaded from the extraction output directory on first API request
    # and cached with a staleness check on the manifest timestamp.
    #
    # @example In Woods configuration:
    #   Woods.configure do |config|
    #     config.svelte_flow_enabled = true
    #     config.svelte_flow_path = '/woods/visualize'
    #   end
    #
    class RackMiddleware # rubocop:disable Metrics/ClassLength
      ASSETS_DIR = File.expand_path('assets', __dir__)
      BUILD_DIR = File.join(ASSETS_DIR, 'build')

      CONTENT_TYPES = {
        '.html' => 'text/html',
        '.js' => 'application/javascript',
        '.css' => 'text/css',
        '.json' => 'application/json',
        '.svg' => 'image/svg+xml'
      }.freeze

      # @param app [#call] The next Rack app in the middleware stack
      # @param path [String] URL path to mount the visualization (default: '/woods/visualize')
      def initialize(app, path: '/woods/visualize')
        @app = app
        @path = path.chomp('/')
        @mutex = Mutex.new
        @transformer = nil
        @manifest_mtime = nil
      end

      # Rack interface — intercepts requests at the configured path.
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def call(env)
        request_path = env['PATH_INFO']
        return @app.call(env) unless request_path.start_with?(@path)

        sub_path = request_path[@path.length..] || ''
        sub_path = '/' if sub_path.empty?

        route_request(sub_path, env)
      end

      private

      # Route a sub-path to the appropriate handler.
      #
      # @param sub_path [String] Path after the mount point
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def route_request(sub_path, env)
        case sub_path
        when '/'                    then serve_html
        when '/api/graph'           then serve_graph_json
        when '/api/clusters'        then serve_clusters_json
        when '/api/flows'           then serve_flows_index
        when '/api/graph/neighbors' then serve_neighbors_json(env)
        else pattern_route(sub_path)
        end
      end

      # Route sub-paths that carry a captured segment (flows, assets).
      #
      # @param sub_path [String] Path after the mount point
      # @return [Array] Rack response triple
      def pattern_route(sub_path)
        case sub_path
        when %r{\A/api/flows/(.+)\z} then serve_flow_json(Regexp.last_match(1))
        when %r{\A/assets/(.+)\z}    then serve_asset(Regexp.last_match(1))
        else not_found
        end
      end

      # Serve the main HTML page with mount path injected into placeholders.
      #
      # @return [Array] Rack response triple
      def serve_html
        html_path = File.join(ASSETS_DIR, 'index.html')
        return not_found unless File.exist?(html_path)

        html = File.read(html_path)
        html = html.gsub('{{BASE_PATH}}', @path)

        [200, { 'content-type' => 'text/html' }, [html]]
      end

      # Serve the dependency graph as Svelte Flow JSON.
      #
      # @return [Array] Rack response triple
      def serve_graph_json
        transformer = ensure_transformer
        return service_unavailable unless transformer

        data = transformer.dependency_graph_data
        json_response(data)
      end

      # Serve domain clusters as Svelte Flow JSON.
      #
      # @return [Array] Rack response triple
      def serve_clusters_json
        transformer = ensure_transformer
        return service_unavailable unless transformer

        data = transformer.domain_cluster_data
        json_response(data)
      end

      # Serve the flow index listing available flows.
      #
      # @return [Array] Rack response triple
      def serve_flows_index
        flow_index = load_flow_index
        json_response(flow_index)
      end

      # Serve a specific flow document as Svelte Flow JSON.
      #
      # @param entry_point_key [String] URL-encoded entry point identifier
      # @return [Array] Rack response triple
      def serve_flow_json(entry_point_key) # rubocop:disable Metrics/CyclomaticComplexity
        transformer = ensure_transformer
        return service_unavailable unless transformer

        # Decode URL-encoded entry point (e.g., "PostsController_create" -> lookup)
        flow_index = load_flow_index
        entry_point = flow_index.keys.find do |ep|
          safe_key(ep) == entry_point_key || ep == entry_point_key
        end

        return not_found unless entry_point

        flow_path = flow_index[entry_point]
        return not_found unless flow_path && File.exist?(flow_path)

        flow_doc = JSON.parse(File.read(flow_path))
        data = transformer.flow_data(flow_doc)
        json_response(data)
      rescue JSON::ParserError, Errno::ENOENT
        not_found
      end

      # Serve a static asset file.
      #
      # @param filename [String] Asset filename
      # @return [Array] Rack response triple
      def serve_asset(filename)
        # Prevent directory traversal
        safe_name = File.basename(filename)

        # Check build directory first, then assets root
        asset_path = File.join(BUILD_DIR, safe_name)
        asset_path = File.join(ASSETS_DIR, safe_name) unless File.exist?(asset_path)
        return not_found unless File.exist?(asset_path)

        ext = File.extname(safe_name)
        content_type = CONTENT_TYPES.fetch(ext, 'application/octet-stream')

        [200, { 'content-type' => content_type }, [File.read(asset_path)]]
      end

      # Thread-safe lazy initialization of the transformer.
      # Re-initializes if the manifest has been updated.
      #
      # @return [Transformer, nil]
      def ensure_transformer
        output_dir = resolve_output_dir
        return nil unless output_dir

        manifest_path = File.join(output_dir, 'manifest.json')
        return nil unless File.exist?(manifest_path)

        current_mtime = File.mtime(manifest_path)

        @mutex.synchronize do
          if @transformer.nil? || @manifest_mtime != current_mtime
            graph_path = File.join(output_dir, 'dependency_graph.json')
            return nil unless File.exist?(graph_path)

            graph_data = JSON.parse(File.read(graph_path))
            graph = DependencyGraph.from_h(graph_data)
            analyzer = GraphAnalyzer.new(graph)
            unit_metadata = load_unit_metadata(output_dir)

            @transformer = Transformer.new(graph: graph, analyzer: analyzer, unit_metadata: unit_metadata)
            @manifest_mtime = current_mtime
          end

          @transformer
        rescue JSON::ParserError, Errno::ENOENT
          nil
        end
      end

      # Load per-unit metadata from extraction output type directories.
      # Scans each type subdirectory for individual unit JSON files and extracts
      # identifier + metadata for NodeBuilder enrichment (columns, attributes).
      #
      # @param output_dir [String] Path to the extraction output directory
      # @return [Hash<String, Hash>] identifier => unit data hash
      def load_unit_metadata(output_dir) # rubocop:disable Metrics
        metadata = {}

        Dir.glob(File.join(output_dir, '*')).each do |type_dir|
          next unless File.directory?(type_dir)
          next if File.basename(type_dir) == 'svelte_flow'
          next if File.basename(type_dir) == 'flows'

          Dir.glob(File.join(type_dir, '*.json')).each do |unit_file|
            next if File.basename(unit_file) == '_index.json'

            unit_data = JSON.parse(File.read(unit_file))
            identifier = unit_data['identifier']
            next unless identifier

            metadata[identifier.to_s] = unit_data
          rescue JSON::ParserError
            next
          end
        end

        metadata
      end

      # Load the flow index from the extraction output.
      #
      # @return [Hash<String, String>]
      def load_flow_index
        output_dir = resolve_output_dir
        return {} unless output_dir

        index_path = File.join(output_dir, 'flows', 'flow_index.json')
        return {} unless File.exist?(index_path)

        JSON.parse(File.read(index_path))
      rescue JSON::ParserError
        {}
      end

      # Resolve the Woods extraction output directory.
      #
      # @return [String, nil]
      def resolve_output_dir
        config = Woods.configuration
        dir = config.output_dir.to_s
        File.directory?(dir) ? dir : nil
      end

      # Generate a URL-safe key from an entry point identifier.
      # Matches the base name logic of FilenameUtils.safe_filename (without .json extension).
      #
      # @param identifier [String]
      # @return [String]
      def safe_key(identifier)
        identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
      end

      # Serve a subgraph scoped to a node's neighborhood at a given BFS depth.
      # Enables progressive loading instead of fetching the full graph upfront.
      #
      # @param env [Hash] Rack environment (reads QUERY_STRING for node and depth params)
      # @return [Array] Rack response triple
      def serve_neighbors_json(env)
        query = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
        node_id = query['node']
        return bad_request('Missing required parameter: node') unless node_id && !node_id.strip.empty?

        transformer = ensure_transformer
        return service_unavailable unless transformer
        return not_found unless transformer.graph.node_exists?(node_id)

        nodes, edges, reverse = graph_adjacency(transformer.graph)
        visited = collect_neighborhood(node_id, clamp_depth(query['depth']), edges: edges, reverse: reverse)

        json_response(build_subgraph_payload(transformer, visited, nodes: nodes, edges: edges, reverse: reverse))
      end

      # Destructure a graph's adjacency maps from its serialized form.
      #
      # @param graph [DependencyGraph]
      # @return [Array(Hash, Hash, Hash)] nodes, forward edges, reverse edges
      def graph_adjacency(graph)
        graph_data = graph.to_h
        [
          graph_data[:nodes] || graph_data['nodes'] || {},
          graph_data[:edges] || graph_data['edges'] || {},
          graph_data[:reverse] || graph_data['reverse'] || {}
        ]
      end

      # Clamp a raw depth query param to the supported 1..5 range.
      #
      # @param raw [String, nil]
      # @return [Integer]
      def clamp_depth(raw)
        (raw || '1').to_i.clamp(1, 5)
      end

      # Build the Svelte Flow subgraph payload for a resolved set of visited
      # node IDs. Shared core behind the neighbor endpoint (and future
      # query-scoped endpoints): scope the graph to `visited`, then run the
      # node and edge builders over the scoped slice.
      #
      # @param transformer [Transformer]
      # @param visited [Set<String>] Node IDs to include
      # @param nodes [Hash] Full node map
      # @param edges [Hash] Full forward-edge map ({ target:, via: } entries)
      # @param reverse [Hash] Full reverse-edge map (identifier-string arrays)
      # @return [Hash] { 'nodes' =>, 'edges' =>, 'highest_pagerank' => }
      def build_subgraph_payload(transformer, visited, nodes:, edges:, reverse:)
        scoped_nodes, scoped_forward, scoped_reverse =
          build_scoped_graph(visited, nodes: nodes, edges: edges, reverse: reverse)

        analyzer = transformer.analyzer
        pagerank_scores = transformer.graph.pagerank

        node_builder = NodeBuilder.new(
          nodes: scoped_nodes, positions: {}, pagerank: pagerank_scores,
          analysis: build_neighbor_analysis(analyzer),
          unit_metadata: transformer.unit_metadata || {},
          forward_edges: scoped_forward, reverse_edges: scoped_reverse
        )
        edge_builder = EdgeBuilder.new(
          edges: scoped_forward, valid_node_ids: visited,
          cycle_edges: build_neighbor_cycle_edges(analyzer, visited)
        )

        {
          'nodes' => node_builder.build,
          'edges' => edge_builder.build,
          'highest_pagerank' => pagerank_scores.max_by { |_k, v| v }&.first
        }
      end

      # BFS from node_id up to depth hops, traversing both forward and reverse edges.
      #
      # @param node_id [String]
      # @param depth [Integer]
      # @param edges [Hash<String, Array<String>>] Forward edges
      # @param reverse [Hash<String, Array<String>>] Reverse edges (serialized as arrays after to_h)
      # @return [Set<String>]
      def collect_neighborhood(node_id, depth, edges:, reverse:)
        visited = Set.new([node_id])
        frontier = [node_id]

        depth.times do
          next_frontier = []
          frontier.each do |current|
            # Forward edges are { target:, via: } hashes; reverse edges are plain identifier strings.
            neighbors = EdgeData.targets(edges[current]) + (reverse[current] || [])
            neighbors.each do |dep|
              next if visited.include?(dep)

              visited.add(dep)
              next_frontier << dep
            end
          end
          frontier = next_frontier
        end

        visited
      end

      # Scope nodes and edges to the visited set.
      #
      # @param visited [Set<String>]
      # @param nodes [Hash] All graph nodes
      # @param edges [Hash<String, Array<String>>] Forward edges
      # @param reverse [Hash<String, Array<String>>] Reverse edges (serialized as arrays)
      # @return [Array(Hash, Hash, Hash)] scoped_nodes, scoped_forward, scoped_reverse
      def build_scoped_graph(visited, nodes:, edges:, reverse:)
        scoped_nodes = {}
        scoped_forward = {}
        scoped_reverse = {}

        visited.each do |source|
          scoped_nodes[source] = nodes[source] if nodes.key?(source)

          # Keep forward entries as { target:, via: } hashes so EdgeBuilder can label edges.
          fwd = select_visited(edges[source], visited) { |entry| EdgeData.target(entry) }
          scoped_forward[source] = fwd unless fwd.empty?

          rev = select_visited(reverse[source], visited) { |target| target }
          scoped_reverse[source] = Set.new(rev) unless rev.empty?
        end

        [scoped_nodes, scoped_forward, scoped_reverse]
      end

      # Select edge entries whose (yielded) target identifier is in `visited`.
      #
      # @param entries [Array, nil] Edge entries for one source
      # @param visited [Set<String>] Node IDs in scope
      # @yieldparam entry [Object] An edge entry
      # @yieldreturn [String, nil] The entry's target identifier
      # @return [Array] Entries kept in scope
      def select_visited(entries, visited)
        (entries || []).select { |entry| visited.include?(yield(entry)) }
      end

      # Build analysis hash for NodeBuilder, scoped gracefully to what the analyzer provides.
      # Returns the same shape as Transformer#build_analysis so NodeBuilder can consume it.
      #
      # @param analyzer [GraphAnalyzer]
      # @return [Hash]
      def build_neighbor_analysis(analyzer)
        {
          hubs: safe_analysis { analyzer.hubs(limit: 20) },
          bridges: safe_analysis { analyzer.bridges(limit: 20) },
          orphans: safe_analysis { analyzer.orphans }
        }
      end

      # Safely call a GraphAnalyzer method, returning [] on any error.
      #
      # @return [Array]
      def safe_analysis
        yield
      rescue StandardError
        []
      end

      # Build cycle edge set scoped to visited node IDs.
      #
      # @param analyzer [GraphAnalyzer]
      # @param visited [Set<String>]
      # @return [Set<Array<String>>]
      def build_neighbor_cycle_edges(analyzer, visited)
        cycle_edges = Set.new
        analyzer.cycles.each do |cycle|
          cycle.each_cons(2) do |a, b|
            cycle_edges.add([a, b]) if visited.include?(a) && visited.include?(b)
          end
        end
        cycle_edges
      rescue StandardError
        Set.new
      end

      # Return a 400 Bad Request response with an error message.
      #
      # @param message [String] Error description
      # @return [Array] Rack response triple
      def bad_request(message)
        [400, { 'content-type' => 'application/json' },
         [JSON.generate({ 'error' => message })]]
      end

      # Return a JSON response.
      #
      # @param data [Hash, Array] Data to serialize
      # @return [Array] Rack response triple
      def json_response(data)
        [200, { 'content-type' => 'application/json' }, [JSON.generate(data)]]
      end

      # Return a 404 response.
      #
      # @return [Array] Rack response triple
      def not_found
        [404, { 'content-type' => 'text/plain' }, ['Not Found']]
      end

      # Return a 503 response when data is not available.
      #
      # @return [Array] Rack response triple
      def service_unavailable
        [503, { 'content-type' => 'application/json' },
         [JSON.generate({ 'error' => 'Extraction data not available. Run `rake woods:extract` first.' })]]
      end
    end
  end
end
