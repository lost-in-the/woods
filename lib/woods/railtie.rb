# frozen_string_literal: true

module Woods
  # Railtie integrates Woods into Rails applications.
  # Loads rake tasks automatically when the gem is bundled.
  # Conditionally inserts session tracer middleware when enabled.
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/woods.rake', __dir__)
    end

    initializer 'woods.session_tracer', after: :load_config_initializers do |app|
      config = Woods.configuration
      next unless config.session_tracer_enabled

      if defined?(Rails) && Rails.env.production? && !config.session_tracer_allow_production
        msg = '[Woods] session tracer disabled in production; ' \
              'set `session_tracer_allow_production = true` to opt in.'
        if defined?(Rails.logger) && Rails.logger
          Rails.logger.warn(msg)
        else
          warn msg
        end
        next
      end

      require 'woods/session_tracer/middleware'

      app.middleware.use(
        Woods::SessionTracer::Middleware,
        store: config.session_store,
        session_id_proc: config.session_id_proc,
        exclude_paths: config.session_exclude_paths
      )
    end

    initializer 'woods.console_mcp', after: :load_config_initializers do |app|
      config = Woods.configuration
      next unless config.console_mcp_enabled

      require 'woods/console/rack_middleware'
      require 'woods/mcp/bearer_auth'
      require 'woods/mcp/origin_guard'

      token = config.console_mcp_token
      production = defined?(Rails) && Rails.env.production?
      token_missing = token.nil? || token.to_s.empty?

      if token_missing
        msg = '[Woods Console] console_mcp_token is not set — Console MCP is a high-privilege ' \
              'endpoint that runs SQL and model introspection against the live database. ' \
              'Set Woods.configuration.console_mcp_token (or WOODS_CONSOLE_MCP_TOKEN env var) ' \
              'to a 32+ character random string.'
        raise Woods::ConfigurationError, msg if production

        # Non-prod without a token: refuse to wire the middleware at all.
        # Earlier iterations fell through and installed the RackMiddleware
        # with ZERO auth/origin guard in front of it — a binding on 0.0.0.0
        # (common in devcontainers/docker-compose) would expose an
        # unauthenticated SQL-bearing endpoint to every local process.
        # Fail-closed: warn and skip.
        warn "#{msg} Refusing to mount the Console MCP middleware until a token is configured."
        next
      end

      # Origin guard first — rejects cross-origin POSTs before any auth cost.
      # BearerAuth next — requires `Authorization: Bearer <token>` on every request.
      app.middleware.use(Woods::MCP::OriginGuard, allowed_origins: Array(config.console_mcp_allowed_origins))
      app.middleware.use(Woods::MCP::BearerAuth, token: token)

      app.middleware.use(
        Woods::Console::RackMiddleware,
        path: config.console_mcp_path,
        embedded_read_tools: config.console_embedded_read_tools
      )
    end

    initializer 'woods.svelte_flow', after: :load_config_initializers do |app|
      config = Woods.configuration
      if config.svelte_flow_enabled
        require 'woods/svelte_flow/rack_middleware'

        app.middleware.use(
          Woods::SvelteFlow::RackMiddleware,
          path: config.svelte_flow_path
        )
      end
    end
  end
end
