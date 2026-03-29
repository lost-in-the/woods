# frozen_string_literal: true

require 'json'
require_relative 'transformer'
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
      def route_request(sub_path, _env)
        case sub_path
        when '/'
          serve_html
        when '/api/graph'
          serve_graph_json
        when '/api/clusters'
          serve_clusters_json
        when '/api/flows'
          serve_flows_index
        when %r{\A/api/flows/(.+)\z}
          serve_flow_json(Regexp.last_match(1))
        when %r{\A/assets/(.+)\z}
          serve_asset(Regexp.last_match(1))
        else
          not_found
        end
      end

      # Serve the main HTML page.
      #
      # @return [Array] Rack response triple
      def serve_html
        html_path = File.join(ASSETS_DIR, 'index.html')
        return not_found unless File.exist?(html_path)

        [200, { 'content-type' => 'text/html' }, [File.read(html_path)]]
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
        asset_path = File.join(ASSETS_DIR, safe_name)
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

            @transformer = Transformer.new(graph: graph, analyzer: analyzer)
            @manifest_mtime = current_mtime
          end

          @transformer
        rescue JSON::ParserError, Errno::ENOENT
          nil
        end
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
