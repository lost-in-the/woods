# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'schema_generator'

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Erd
    # Rack middleware that serves the Liam ERD visualization.
    #
    # Intercepts requests at a configurable path and serves:
    # - Pre-built Liam SPA static assets (HTML, JS, CSS)
    # - Dynamically generated schema.json from Woods extracted model units
    #
    # Schema JSON is generated on first request and cached in memory.
    #
    # @example In config/application.rb via Railtie:
    #   # Automatically inserted when config.erd_enabled = true
    #   config.middleware.use Woods::Erd::RackMiddleware, path: '/woods/erd'
    #
    class RackMiddleware
      CONTENT_TYPES = {
        '.html' => 'text/html',
        '.js' => 'application/javascript',
        '.css' => 'text/css',
        '.json' => 'application/json',
        '.svg' => 'image/svg+xml',
        '.png' => 'image/png',
        '.ico' => 'image/x-icon',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2'
      }.freeze

      # @param app [#call] The next Rack app in the middleware stack
      # @param path [String] URL path to mount the ERD (default: '/woods/erd')
      # @param output_dir [String, Pathname] Woods extraction output directory
      # @param assets_dir [String, Pathname, nil] Override for vendored assets location
      def initialize(app, path: '/woods/erd', output_dir: nil, assets_dir: nil)
        @app = app
        @path = path.chomp('/')
        @output_dir = output_dir&.to_s || default_output_dir
        @assets_dir = Pathname.new(assets_dir || default_assets_dir).cleanpath
        @cached_schema = nil
      end

      # Rack interface — intercepts requests at the configured path.
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def call(env)
        request_path = env['PATH_INFO']

        return @app.call(env) unless request_path.start_with?(@path)

        relative_path = request_path[@path.length..] || ''

        # Redirect /woods/erd to /woods/erd/ so relative asset paths resolve correctly
        return [301, { 'location' => "#{@path}/", 'content-length' => '0' }, []] if relative_path.empty?

        serve(relative_path)
      end

      private

      # Route a request to the appropriate handler.
      #
      # @param relative_path [String] Path relative to the mount point
      # @return [Array] Rack response triple
      def serve(relative_path)
        case relative_path
        when '/', '/index.html'
          serve_file('index.html')
        when '/schema.json'
          serve_schema
        else
          serve_file(relative_path.delete_prefix('/'))
        end
      end

      # Serve a static file from the assets directory.
      #
      # @param filename [String] Relative path within assets directory
      # @return [Array] Rack response triple
      def serve_file(filename)
        # Prevent path traversal
        file_path = @assets_dir.join(filename).cleanpath
        return not_found unless file_path.to_s.start_with?(@assets_dir.to_s)
        return not_found unless file_path.file?

        ext = file_path.extname
        content_type = CONTENT_TYPES[ext] || 'application/octet-stream'
        body = file_path.binread

        [200, { 'content-type' => content_type, 'content-length' => body.bytesize.to_s }, [body]]
      end

      # Serve the generated schema JSON, caching after first generation.
      #
      # @return [Array] Rack response triple
      def serve_schema
        @cached_schema ||= generate_schema
        [200, { 'content-type' => 'application/json', 'content-length' => @cached_schema.bytesize.to_s },
         [@cached_schema]]
      rescue Woods::Error => e
        error_json = JSON.generate({ 'error' => e.message })
        [503, { 'content-type' => 'application/json', 'content-length' => error_json.bytesize.to_s }, [error_json]]
      end

      # Generate schema JSON from extracted model units.
      #
      # @return [String] JSON string
      def generate_schema
        layers = if defined?(Woods) && Woods.respond_to?(:configuration) && Woods.configuration
                   Woods.configuration.erd_layers
                 else
                   [:models]
                 end
        schema = SchemaGenerator.new(@output_dir, layers: layers).generate
        JSON.generate(schema)
      end

      # @return [Array] 404 response
      def not_found
        [404, { 'content-type' => 'text/plain', 'content-length' => '9' }, ['Not Found']]
      end

      # @return [String] Default output directory
      def default_output_dir
        if defined?(Rails) && Rails.root
          Rails.root.join('tmp/woods').to_s
        else
          'tmp/woods'
        end
      end

      # @return [String] Default vendored assets directory
      def default_assets_dir
        File.expand_path('../../../vendor/assets/liam-erd', __dir__)
      end
    end
  end
end
