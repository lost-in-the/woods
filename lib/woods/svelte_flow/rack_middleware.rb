# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'transformer'
require_relative 'subgraph_scoper'
require_relative 'source_links'
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
        when '/api/subgraph'        then serve_subgraph_json(env)
        else pattern_route(sub_path)
        end
      end

      # Route sub-paths that carry a captured segment (flows, assets).
      #
      # @param sub_path [String] Path after the mount point
      # @return [Array] Rack response triple
      def pattern_route(sub_path)
        case sub_path
        when %r{\A/api/unit/(.+)/source\z} then serve_unit_source(Rack::Utils.unescape(Regexp.last_match(1)))
        when %r{\A/api/flows/(.+)\z}       then serve_flow_json(Regexp.last_match(1))
        when %r{\A/assets/(.+)\z}          then serve_asset(Regexp.last_match(1))
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

      # Serve a unit's source code and file links for the sidebar detail pane.
      # Looked up by identifier against the extracted metadata — never a raw
      # path — so this cannot be turned into an arbitrary-file read.
      #
      # @param identifier [String] Unit identifier
      # @return [Array] Rack response triple
      def serve_unit_source(identifier)
        transformer = ensure_transformer
        return service_unavailable unless transformer

        unit = transformer.unit_metadata[identifier]
        return not_found unless unit

        file_path = unit['file_path'] || unit[:file_path]
        json_response(
          'identifier' => identifier,
          'filePath' => file_path,
          'sourceCode' => unit['source_code'] || unit[:source_code],
          'blobUrl' => github_blob_url(file_path)
        )
      end

      # Build a GitHub blob URL for a file via the shared SourceLinks helper.
      #
      # @param file_path [String, nil]
      # @return [String, nil]
      def github_blob_url(file_path)
        SourceLinks.github_blob_url(file_path,
                                    repo_url: Woods.configuration.svelte_flow_repo_url,
                                    git_sha: manifest_git_sha)
      end

      # Read the extraction's git SHA from the manifest, if present.
      #
      # @return [String, nil]
      def manifest_git_sha
        dir = resolve_output_dir
        return nil unless dir

        manifest = JSON.parse(File.read(File.join(dir, 'manifest.json')))
        manifest['git_sha']
      rescue JSON::ParserError, Errno::ENOENT
        nil
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

        payload = SubgraphScoper.new(transformer).payload(seeds: node_id, depth: clamp_depth(query['depth']))
        json_response(payload)
      end

      # Serve a subgraph scoped to an arbitrary set of node identifiers — the
      # rendered form of an agent's query result (dependents, a flow, a search).
      #
      # Query params:
      # - nodes  (required) comma-separated identifiers to render
      # - depth  (optional, default 0, max 5) extra BFS hops pulled in around the set
      # - via    (optional) comma-separated relationship filter (e.g. belongs_to,render)
      #
      # Unknown identifiers are dropped and reported back in `dropped`.
      #
      # @param env [Hash] Rack environment (reads QUERY_STRING)
      # @return [Array] Rack response triple
      def serve_subgraph_json(env)
        query = Rack::Utils.parse_query(env['QUERY_STRING'] || '')
        requested = parse_id_list(query['nodes'])
        return bad_request('Missing required parameter: nodes') if requested.empty?

        transformer = ensure_transformer
        return service_unavailable unless transformer

        known, dropped = requested.partition { |id| transformer.graph.node_exists?(id) }
        return not_found('None of the requested nodes exist', dropped: dropped) if known.empty?

        payload = SubgraphScoper.new(transformer).payload(
          seeds: known, depth: clamp_depth(query['depth'], min: 0), via_set: parse_via(query['via'])
        )
        json_response(payload.merge('requested' => known, 'dropped' => dropped))
      end

      # Parse a comma-separated identifier list, trimming blanks and duplicates.
      #
      # @param raw [String, nil]
      # @return [Array<String>]
      def parse_id_list(raw)
        (raw || '').split(',').map(&:strip).reject(&:empty?).uniq
      end

      # Parse a comma-separated relationship (`via`) filter into a symbol set.
      #
      # @param raw [String, nil]
      # @return [Set<Symbol>, nil] nil when no filter was supplied
      def parse_via(raw)
        labels = parse_id_list(raw).map(&:to_sym)
        labels.empty? ? nil : Set.new(labels)
      end

      # Clamp a raw depth query param to the supported range. `min` is also the
      # default when the param is absent (1 for neighbors, 0 for subgraphs).
      #
      # @param raw [String, nil]
      # @param min [Integer] Lower bound and default
      # @return [Integer]
      def clamp_depth(raw, min: 1)
        (raw || min.to_s).to_i.clamp(min, 5)
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

      # Return a 404 response. Plain text by default; JSON (with an optional
      # `dropped` list) when a message is supplied.
      #
      # @param message [String, nil] Error message; nil yields a plain-text 404
      # @param dropped [Array<String>, nil] Unresolved identifiers to report
      # @return [Array] Rack response triple
      def not_found(message = nil, dropped: nil)
        return [404, { 'content-type' => 'text/plain' }, ['Not Found']] if message.nil?

        body = { 'error' => message }
        body['dropped'] = dropped if dropped
        [404, { 'content-type' => 'application/json' }, [JSON.generate(body)]]
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
