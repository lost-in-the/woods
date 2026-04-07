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
      if config.session_tracer_enabled
        require 'woods/session_tracer/middleware'

        app.middleware.use(
          Woods::SessionTracer::Middleware,
          store: config.session_store,
          session_id_proc: config.session_id_proc,
          exclude_paths: config.session_exclude_paths
        )
      end
    end

    initializer 'woods.console_mcp' do |app|
      config = Woods.configuration
      if config.console_mcp_enabled
        require 'woods/console/rack_middleware'

        app.middleware.use(
          Woods::Console::RackMiddleware,
          path: config.console_mcp_path
        )
      end
    end

    initializer 'woods.erd' do |app|
      config = Woods.configuration
      if config.erd_enabled
        require 'woods/erd/rack_middleware'

        app.middleware.use(
          Woods::Erd::RackMiddleware,
          path: config.erd_path,
          output_dir: config.output_dir
        )
      end
    end
  end
end
