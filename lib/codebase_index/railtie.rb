# frozen_string_literal: true

module CodebaseIndex
  # Railtie integrates CodebaseIndex into Rails applications.
  # Loads rake tasks automatically when the gem is bundled.
  # Conditionally inserts session tracer middleware when enabled.
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/codebase_index.rake', __dir__)
    end

    initializer 'codebase_index.session_tracer' do |app|
      config = CodebaseIndex.configuration
      if config.session_tracer_enabled
        require 'codebase_index/session_tracer/middleware'

        app.middleware.use(
          CodebaseIndex::SessionTracer::Middleware,
          store: config.session_store,
          session_id_proc: config.session_id_proc,
          exclude_paths: config.session_exclude_paths
        )
      end
    end

    initializer 'codebase_index.console_mcp' do |app|
      config = CodebaseIndex.configuration
      if config.console_mcp_enabled
        require 'codebase_index/console/rack_middleware'

        app.middleware.use(
          CodebaseIndex::Console::RackMiddleware,
          path: config.console_mcp_path
        )
      end
    end
  end
end
