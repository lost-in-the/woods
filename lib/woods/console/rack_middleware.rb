# frozen_string_literal: true

require 'json'
require 'woods/observability/structured_logger'

module Woods
  module Console
    # Rack middleware that serves the embedded console MCP server over HTTP.
    #
    # Lazy-builds the MCP server on first request so Rails has fully booted
    # and all models are loaded. Uses ActiveRecord connection pool for thread
    # safety under Puma.
    #
    # == Basic setup (Tier 1 tools only)
    #
    # Add to config/application.rb or an initializer:
    #
    #   config.middleware.use Woods::Console::RackMiddleware, path: '/mcp/console'
    #
    # This mounts 31 console tools at /mcp/console. By default, console_sql and
    # console_query are blocked in embedded mode and return an "unsupported" error
    # pointing users to enable the flag.
    #
    # == Enabling the feature
    #
    # The Console MCP is disabled by default. Enable it in your Woods initializer:
    #
    #   Woods.configure do |config|
    #     config.console_mcp_enabled = true
    #     config.console_blocked_tables = %w[authorizations credentials]
    #     config.console_redacted_columns = %w[api_token password_digest]
    #   end
    #
    # With the flag off, requests to the mounted path return 410 Gone so
    # operators can see the endpoint exists but is gated. See
    # docs/CONSOLE_MCP_SETUP.md for the full security posture (blocked tables,
    # credential scanner, column/EAV redaction, SafeContext rollback).
    #
    # == Enabling read tools (console_sql + console_query)
    #
    # Set embedded_read_tools: true to unlock the sql and query tools:
    #
    #   # config/initializers/woods_console.rb
    #   Rails.application.config.middleware.use \
    #     Woods::Console::RackMiddleware,
    #     path: '/mcp/console',
    #     embedded_read_tools: true
    #
    # Security posture with embedded_read_tools: true:
    #
    # 1. SqlValidator denylist — console_sql rejects INSERT/UPDATE/DELETE/DROP/TRUNCATE/
    #    ALTER/CREATE/REPLACE and similar DML/DDL at the string level before any database
    #    interaction. Only SELECT and WITH...SELECT are allowed.
    #
    # 2. SafeContext rollback — every request (including console_query) runs inside
    #    a database transaction that is always rolled back on completion. Even if a
    #    query somehow mutated state (e.g. a function with side effects), the rollback
    #    ensures nothing persists.
    #
    # 3. Per-request connection pooling — each HTTP request draws a connection from
    #    ActiveRecord::Base's pool and returns it after the response. No shared
    #    mutable state leaks between requests.
    #
    # These three layers make embedded_read_tools: true safe for read-only workloads.
    # If your threat model requires stricter isolation, use the bridge mode instead
    # (docs/CONSOLE_MCP_SETUP.md) which runs the executor in a separate process.
    #
    class RackMiddleware
      # @param app [#call] The next Rack app in the middleware stack
      # @param path [String] URL path to mount the MCP endpoint (default: '/mcp/console')
      # @param embedded_read_tools [Boolean] Enable sql/query tools in embedded mode (default: false)
      def initialize(app, path: '/mcp/console', embedded_read_tools: false)
        @app = app
        @path = path
        @embedded_read_tools = embedded_read_tools
        @mutex = Mutex.new
        @transport = nil
      end

      DISABLED_BODY = JSON.generate(
        error: 'woods_console_disabled',
        message: 'Woods Console MCP is disabled. Set ' \
                 'Woods.configuration.console_mcp_enabled = true to enable. ' \
                 'See docs/CONSOLE_MCP_SETUP.md for the full security posture.'
      ).freeze

      # Rack interface — intercepts requests at the configured path.
      #
      # Returns 410 Gone when Woods.configuration.console_mcp_enabled is false
      # (the default). This keeps the middleware inert on hosts that have
      # mounted it but not yet opted into the feature. All other requests at
      # non-matching paths pass through to the wrapped app unchanged.
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def call(env)
        return @app.call(env) unless env['PATH_INFO'].start_with?(@path)
        return [410, { 'content-type' => 'application/json' }, [DISABLED_BODY]] unless enabled?

        ensure_transport.handle_request(Rack::Request.new(env))
      end

      private

      def enabled?
        Woods.configuration.console_mcp_enabled
      end

      # Thread-safe lazy initialization of the MCP server and transport.
      #
      # @return [::MCP::Server::Transports::StreamableHTTPTransport]
      def ensure_transport
        return @transport if @transport

        @mutex.synchronize do
          return @transport if @transport

          require 'woods/console/server'
          Rails.application.eager_load!

          server = build_embedded_server
          @transport = ::MCP::Server::Transports::StreamableHTTPTransport.new(server)
          server.transport = @transport
          @transport
        end
      end

      # Build the embedded MCP server. SafeContext is given the writing
      # connection pool (not a connection) so each request leases a fresh
      # connection via `pool.with_connection { ... }` and returns it to the
      # pool when the rolled-back transaction completes. Capturing a
      # connection at build time would leak it out of its lease and pin it
      # for the lifetime of the process.
      #
      # Multi-DB / sharded hosts are still served from the writing pool
      # only — extending SafeContext to route per role/shard is tracked as
      # `WOODS-CONSOLE-PERREQ-CONN`.
      def build_embedded_server
        config = Woods.configuration
        introspection = build_model_introspection
        Server.build_embedded(
          model_validator: ModelValidator.new(registry: introspection[:registry]),
          safe_context: SafeContext.new(pool: ActiveRecord::Base.connection_pool),
          redacted_columns: Array(config&.console_redacted_columns),
          redacted_key_values: Array(config&.console_redacted_key_values),
          read_tools_enabled: @embedded_read_tools,
          model_tables: introspection[:tables],
          model_reflections: introspection[:reflections]
        )
      end

      # Walk ActiveRecord::Base.descendants once and collect the registry,
      # table map, and reflection map in a single pass. Models that raise
      # during introspection are silently skipped — same semantics as the
      # three separate methods this replaces.
      #
      # Map every model to its association-name → target-table registry so
      # TableGate can resolve `joins:` / `association:` arguments before the
      # executor loads data. Polymorphic associations and anything that
      # raises during reflection are skipped gracefully.
      #
      # @return [Hash] frozen hash with keys :registry, :tables, :reflections
      def build_model_introspection
        registry = {}
        tables = {}
        reflections = {}

        ActiveRecord::Base.descendants.each do |model|
          next if model.abstract_class?
          next unless model.table_exists?

          registry[model.name] = model.column_names
          tables[model.name] = model.table_name
          reflections[model.name] = reflections_for(model)
        rescue StandardError => e
          structured_logger.debug(
            'console.model_introspection.skipped',
            model: model.name,
            error_class: e.class.name,
            error_message: e.message
          )
          next
        end

        { registry: registry, tables: tables, reflections: reflections }.freeze
      end

      def reflections_for(model)
        model.reflect_on_all_associations.each_with_object({}) do |reflection, assoc_map|
          next if reflection.polymorphic?

          klass = reflection.klass
          assoc_map[reflection.name.to_s] = klass.table_name if klass.respond_to?(:table_name)
        rescue StandardError
          next
        end
      end

      def structured_logger
        @structured_logger ||= Woods::Observability::StructuredLogger.new
      end
    end
  end
end
