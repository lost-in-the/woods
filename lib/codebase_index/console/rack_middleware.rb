# frozen_string_literal: true

require 'json'

module CodebaseIndex
  module Console
    # Rack middleware that serves the embedded console MCP server over HTTP.
    #
    # Lazy-builds the MCP server on first request so Rails has fully booted
    # and all models are loaded. Uses ActiveRecord connection pool for thread
    # safety under Puma.
    #
    # @example In config/application.rb or an initializer:
    #   config.middleware.use CodebaseIndex::Console::RackMiddleware, path: '/mcp/console'
    #
    class RackMiddleware
      # @param app [#call] The next Rack app in the middleware stack
      # @param path [String] URL path to mount the MCP endpoint (default: '/mcp/console')
      def initialize(app, path: '/mcp/console')
        @app = app
        @path = path
        @mutex = Mutex.new
        @transport = nil
      end

      # Rack interface — intercepts requests at the configured path.
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def call(env)
        return @app.call(env) unless env['PATH_INFO'].start_with?(@path)

        transport = ensure_transport
        request = Rack::Request.new(env)
        transport.handle_request(request)
      end

      private

      # Thread-safe lazy initialization of the MCP server and transport.
      #
      # @return [MCP::Server::Transports::StreamableHTTPTransport]
      def ensure_transport # rubocop:disable Metrics/MethodLength
        return @transport if @transport

        @mutex.synchronize do
          return @transport if @transport

          require 'codebase_index/console/server'

          Rails.application.eager_load!

          registry = ActiveRecord::Base.descendants.each_with_object({}) do |model, hash|
            next if model.abstract_class?
            next unless model.table_exists?

            hash[model.name] = model.column_names
          rescue StandardError
            next
          end

          validator = ModelValidator.new(registry: registry)

          config = CodebaseIndex.configuration
          redacted = Array(config.console_redacted_columns)

          # Each HTTP request gets its own connection from the pool.
          # SafeContext wraps that connection in a rolled-back transaction.
          safe_context = SafeContext.new(connection: ActiveRecord::Base.connection)

          server = Server.build_embedded(
            model_validator: validator,
            safe_context: safe_context,
            redacted_columns: redacted
          )

          @transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
          server.transport = @transport
          @transport
        end
      end
    end
  end
end
