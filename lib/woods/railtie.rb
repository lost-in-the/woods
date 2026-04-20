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

    initializer 'woods.console_mcp', after: :load_config_initializers do |app|
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
