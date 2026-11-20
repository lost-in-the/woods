# frozen_string_literal: true

module Woods
  # Rails-independent logic behind {Woods::Railtie}.
  #
  # Rails railtie initializers run before `:load_config_initializers`, so
  # anything the railtie reads from Woods.configuration at initializer time
  # sees the defaults — not the values set in `config/initializers/woods.rb`
  # (the generator-created location every doc names). The settled
  # configuration is validated from an `after_initialize` hook (#183).
  #
  # This module carries no Rails dependency so the gem's unit specs can
  # exercise boot-time verification without loading Rails::Railtie.
  module RailtieSupport
    class << self
      # @return [Symbol, nil] `:mounted` when the session tracer middleware
      #   was inserted, `:skipped_production` when the production guard
      #   refused it, nil when the flag was off at railtie-initializer time.
      attr_accessor :session_tracer_state

      # The live configuration, initialized to defaults when the host never
      # called Woods.configure: the railtie runs in every app, so nothing
      # here may assume a configure block ran.
      #
      # @return [Woods::Configuration]
      def config
        Woods.configuration || Woods.configure
      end

      # Boot-time session tracer validation, run from `after_initialize`.
      # SessionTracer::Middleware requires a store at construction, so it
      # cannot be mounted lazily — when the flag was
      # set too late for the railtie initializer to see it, warn with the
      # remediation instead of silently doing nothing (#183).
      #
      # @return [void]
      def verify_session_tracer_configuration!
        return unless config.session_tracer_enabled
        return unless session_tracer_state.nil?

        warn '[Woods] session_tracer_enabled is set but the middleware was not mounted: ' \
             'the flag was enabled after Rails railtie initializers ran (config/initializers/ ' \
             'runs later). Set session_tracer_enabled and session_store in ' \
             'config/application.rb, then restart.'
      end
    end
  end
end
