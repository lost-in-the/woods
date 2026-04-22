# frozen_string_literal: true

module Woods
  # Railtie integrates Woods into Rails applications.
  # Loads rake tasks automatically when the gem is bundled.
  # Conditionally inserts session tracer middleware when enabled.
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/woods.rake', __dir__)
    end

    initializer 'woods.session_tracer' do |app|
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

    initializer 'woods.console_mcp' do |app|
      config = Woods.configuration
      if config.console_mcp_enabled
        require 'woods/console/rack_middleware'

        app.middleware.use(
          Woods::Console::RackMiddleware,
          path: config.console_mcp_path,
          embedded_read_tools: config.console_embedded_read_tools
        )
      end
    end
  end
end
