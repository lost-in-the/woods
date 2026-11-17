# frozen_string_literal: true

require 'woods/railtie_support'

module Woods
  # Railtie integrates Woods into Rails applications.
  # Loads rake tasks automatically when the gem is bundled.
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
      # Loaded here too, or `woods:evaluate` exists on no host — the file
      # shipped in the gem for its whole life without ever being loaded, so
      # the retrieval-quality harness had no entry point at all (#212).
      load File.expand_path('../tasks/woods_evaluation.rake', __dir__)
      # Read-only checks over retained generations (#280); no Rails boot.
      load File.expand_path('../tasks/woods_checks.rake', __dir__)
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

    # Runs after :load_config_initializers, when the configuration is final —
    # this is where boot-time validation belongs (#183).
    config.after_initialize do
      Woods::RailtieSupport.verify_session_tracer_configuration!
    end
  end
end
