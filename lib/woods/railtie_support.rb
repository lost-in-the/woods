# frozen_string_literal: true

module Woods
  # Rails-independent logic behind {Woods::Railtie}.
  #
  # Rails railtie initializers run before `:load_config_initializers`, so
  # anything the railtie reads from Woods.configuration at initializer time
  # sees the defaults — not the values set in `config/initializers/woods.rb`
  # (the generator-created location every doc names). The railtie therefore
  # mounts the console stack unconditionally and defers every decision to
  # request time via the procs below, and validates the settled
  # configuration from an `after_initialize` hook (#183).
  #
  # This module carries no Rails dependency so the gem's unit specs can
  # exercise the request-time procs and boot-time verification without
  # loading Rails::Railtie.
  module RailtieSupport
    # Boot-time message for a console enabled without a token. Raised in
    # production; warned everywhere else (HTTP requests fail closed with 401
    # either way — see {Woods::MCP::BearerAuth}).
    MISSING_TOKEN_MESSAGE =
      '[Woods Console] console_mcp_token is not set — Console MCP is a high-privilege ' \
      'endpoint that runs SQL and model introspection against the live database. ' \
      'Set Woods.configuration.console_mcp_token (or WOODS_CONSOLE_MCP_TOKEN env var) ' \
      'to a 32+ character random string.'

    # Transport qualifier appended to {MISSING_TOKEN_MESSAGE} outside
    # production (G-3). The token authenticates the *HTTP* Console transport
    # only: {Woods::Console::RackMiddleware} and {Woods::MCP::BearerAuth} are
    # what return the 401. The stdio transport (`rake woods:console`,
    # `exe/woods-console`) speaks over a pipe and neither sends nor consumes a
    # bearer token, so an unqualified "requests will be refused (401)" sent
    # stdio-only operators configuring a token their setup never uses.
    MISSING_TOKEN_TRANSPORT_NOTE =
      'The token authenticates the Console MCP HTTP transport: without it every HTTP ' \
      'request is refused (401). The stdio transport (rake woods:console) does not ' \
      'transmit or use a bearer token, so a stdio-only setup still works — set the token ' \
      'before exposing the HTTP endpoint.'

    class << self
      # @return [String, nil] path the console stack was mounted at (captured
      #   at railtie-initializer time). Used by
      #   {.verify_console_configuration!} to detect a `console_mcp_path`
      #   set too late to take effect.
      attr_accessor :console_mounted_path

      # @return [Symbol, nil] `:mounted` when the session tracer middleware
      #   was inserted, `:skipped_production` when the production guard
      #   refused it, nil when the flag was off at railtie-initializer time.
      attr_accessor :session_tracer_state

      # Request-time predicate handed to the console guards and consulted by
      # {Woods::Console::RackMiddleware}. Reads the live configuration on
      # every call, so a flag set after the middleware was inserted (e.g. in
      # config/initializers) still takes effect.
      #
      # @return [Proc] arity-0 proc returning the current enabled flag
      def console_enabled_proc
        -> { config.console_mcp_enabled }
      end

      # Deferred bearer token for {Woods::MCP::BearerAuth}, resolved on each
      # guarded request.
      #
      # @return [Proc] arity-0 proc returning the configured token (or nil)
      def console_token_proc
        -> { config.console_mcp_token }
      end

      # Deferred origin allow-list for {Woods::MCP::OriginGuard}, resolved on
      # the first guarded request.
      #
      # @return [Proc] arity-0 proc returning the configured allow-list
      def console_allowed_origins_proc
        -> { Array(config.console_mcp_allowed_origins) }
      end

      # Deferred read-tools flag for {Woods::Console::RackMiddleware},
      # resolved when the embedded server is first built.
      #
      # @return [Proc] arity-0 proc returning the configured flag
      def console_read_tools_proc
        -> { config.console_embedded_read_tools }
      end

      # The live configuration, initialized to defaults when the host never
      # called Woods.configure — the console stack is mounted in every app
      # now, so nothing here may assume a configure block ran.
      #
      # @return [Woods::Configuration]
      def config
        Woods.configuration || Woods.configure
      end

      # Boot-time console validation, run from `after_initialize` once the
      # final configuration is known. With the console enabled and no usable
      # token, every guarded request will be refused with 401 — production
      # refuses to boot instead (matching the pre-#183 fail-closed posture),
      # other environments warn loudly. A token shorter than
      # {Woods::MCP::BearerAuth::MIN_TOKEN_LENGTH} is a misconfiguration and
      # raises in every environment (as the eager BearerAuth constructor
      # used to). Also warns when `console_mcp_path` changed after the stack
      # was mounted.
      #
      # @param production [Boolean] whether the app runs in production
      # @return [void]
      # @raise [Woods::ConfigurationError] on a missing token in production,
      #   or a too-short token anywhere
      def verify_console_configuration!(production:)
        warn_late_console_path(config)
        return unless config.console_mcp_enabled

        require 'woods/mcp/bearer_auth'
        token = config.console_mcp_token.to_s
        if token.empty?
          raise Woods::ConfigurationError, MISSING_TOKEN_MESSAGE if production

          warn "#{MISSING_TOKEN_MESSAGE} #{MISSING_TOKEN_TRANSPORT_NOTE}"
        elsif token.length < Woods::MCP::BearerAuth::MIN_TOKEN_LENGTH
          raise Woods::ConfigurationError,
                '[Woods Console] console_mcp_token is shorter than ' \
                "#{Woods::MCP::BearerAuth::MIN_TOKEN_LENGTH} characters; generate one with " \
                '`SecureRandom.hex(32)` (or `rake woods:generate_token`).'
        end
      end

      # Boot-time session tracer validation, run from `after_initialize`.
      # Unlike the console stack, SessionTracer::Middleware requires a store
      # at construction, so it cannot be mounted lazily — when the flag was
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

      private

      # Warn when the configured console path no longer matches the path the
      # stack was mounted at — the path was set after railtie initializers
      # captured the middleware arguments.
      #
      # @param config [Woods::Configuration]
      # @return [void]
      def warn_late_console_path(config)
        mounted = console_mounted_path
        return if mounted.nil? || mounted == config.console_mcp_path

        warn "[Woods Console] console_mcp_path is #{config.console_mcp_path.inspect} but the " \
             "console stack was mounted at #{mounted.inspect} — the path was changed after " \
             'Rails railtie initializers ran. Set console_mcp_path in config/application.rb, ' \
             'then restart.'
      end
    end
  end
end
