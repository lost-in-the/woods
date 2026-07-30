# frozen_string_literal: true

require 'woods/railtie_support'

module Woods
  # Railtie integrates Woods into Rails applications.
  # Loads rake tasks automatically when the gem is bundled.
  #
  # == Console MCP (#183)
  #
  # The console stack (OriginGuard -> BearerAuth -> Console::RackMiddleware)
  # is mounted unconditionally, but every decision is deferred to request
  # time: railtie initializers run before `:load_config_initializers`, so
  # flags and tokens set in `config/initializers/woods.rb` (the
  # generator-created location) do not exist yet when middleware arguments
  # are captured. Both guards are scoped to `console_mcp_path` — requests
  # outside it pass through untouched — and while `console_mcp_enabled` is
  # false the whole stack passes through, so an unconfigured host app is
  # completely unaffected. Boot-time validation of the settled configuration
  # happens in `after_initialize` via {Woods::RailtieSupport}.
  #
  # == Session tracer
  #
  # SessionTracer::Middleware requires a store at construction, so it cannot
  # be mounted lazily. It stays conditionally mounted, and the
  # `after_initialize` hook warns when the flag was set too late to mount
  # (i.e. in config/initializers instead of config/application.rb).
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/woods.rake', __dir__)
    end

    initializer 'woods.session_tracer' do |app|
      # RailtieSupport.config initializes defaults when the host app never
      # called Woods.configure — this initializer runs in every app.
      config = Woods::RailtieSupport.config
      Woods::RailtieSupport.session_tracer_state = nil
      next unless config.session_tracer_enabled

      if defined?(Rails) && Rails.env.production? && !config.session_tracer_allow_production
        msg = '[Woods] session tracer disabled in production; ' \
              'set `session_tracer_allow_production = true` to opt in.'
        if defined?(Rails.logger) && Rails.logger
          Rails.logger.warn(msg)
        else
          warn msg
        end
        Woods::RailtieSupport.session_tracer_state = :skipped_production
        next
      end

      require 'woods/session_tracer/middleware'

      app.middleware.use(
        Woods::SessionTracer::Middleware,
        store: config.session_store,
        session_id_proc: config.session_id_proc,
        exclude_paths: config.session_exclude_paths
      )
      Woods::RailtieSupport.session_tracer_state = :mounted
    end

    initializer 'woods.console_mcp' do |app|
      require 'woods/console/rack_middleware'
      require 'woods/mcp/bearer_auth'
      require 'woods/mcp/origin_guard'

      # Mounted unconditionally; enablement, token, and allow-list are all
      # resolved at request time (see RailtieSupport) so values set in
      # config/initializers take effect. The path is the one thing captured
      # now — changing console_mcp_path must happen in config/application.rb
      # (after_initialize warns otherwise).
      path = Woods::RailtieSupport.config.console_mcp_path
      Woods::RailtieSupport.console_mounted_path = path
      enabled = Woods::RailtieSupport.console_enabled_proc

      # Origin guard first — rejects cross-origin POSTs before any auth cost.
      # BearerAuth next — requires `Authorization: Bearer <token>` at the
      # console path, failing closed (401) while no usable token is
      # configured. Both are scoped to the console path and inert while
      # console_mcp_enabled is false.
      app.middleware.use(
        Woods::MCP::OriginGuard,
        allowed_origins: Woods::RailtieSupport.console_allowed_origins_proc,
        path: path,
        enabled: enabled
      )
      app.middleware.use(
        Woods::MCP::BearerAuth,
        token: Woods::RailtieSupport.console_token_proc,
        path: path,
        enabled: enabled
      )

      app.middleware.use(
        Woods::Console::RackMiddleware,
        path: path,
        embedded_read_tools: Woods::RailtieSupport.console_read_tools_proc
      )
    end

    # Runs after :load_config_initializers, when the configuration is final —
    # this is where boot-time validation belongs (#183).
    config.after_initialize do
      Woods::RailtieSupport.verify_console_configuration!(
        production: defined?(Rails) && Rails.env.production?
      )
      Woods::RailtieSupport.verify_session_tracer_configuration!
    end
  end
end
