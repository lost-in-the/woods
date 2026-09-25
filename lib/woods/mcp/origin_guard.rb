# frozen_string_literal: true

require 'json'

require_relative 'origin_policy'

module Woods
  module MCP
    # Rack middleware that rejects browser-origin requests from unexpected sources.
    #
    # Defends against DNS rebinding and cross-site request forgery against a
    # locally-bound MCP HTTP server. Defaults to loopback-only origins; operators
    # can widen via WOODS_MCP_HTTP_ALLOWED_ORIGINS (comma-separated) or by passing
    # :allowed_origins. Requests without an Origin header (curl, server-to-server,
    # MCP stdio clients) are allowed through — bearer auth still gates them.
    #
    # Host header validation defends against the residual DNS-rebinding surface:
    # an attacker who controls a hostname they can point at the server's IP can
    # pass the Origin check (the browser sends their origin, which we might
    # allow-list for some deployments) while Host carries their hostname. By
    # also requiring Host to appear in the allow-list (or to be a loopback
    # address), we close that gap even when Rails is bound to 0.0.0.0.
    #
    # Cross-origin entries match exactly. A portless entry also permits
    # same-authority requests on other ports; cross-port browser clients need
    # their actual origin explicitly configured, as required by the SDK.
    #
    # Also answers CORS preflight (OPTIONS) with the matching allow-list.
    class OriginGuard
      DEFAULT_ALLOWED = OriginPolicy::DEFAULT_ORIGINS

      # Hosts that always pass the Host-header check even without an explicit
      # allow-list entry — they resolve to loopback by definition and cannot
      # be rebound to an attacker-controlled address.
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

      ALLOWED_METHODS = 'GET, POST, DELETE, OPTIONS'
      ALLOWED_HEADERS = 'Authorization, Content-Type, MCP-Protocol-Version, Mcp-Method, Mcp-Name, Mcp-Session-Id'

      # Response bodies are emitted as constants so the rejected Origin /
      # Host value is NEVER echoed back to the caller — preventing a
      # stored-XSS / log-injection surface where an attacker-supplied
      # header ended up embedded in the JSON error.
      FORBIDDEN_BODY = { jsonrpc: '2.0', error: { code: -32_002, message: 'Origin not allowed' }, id: nil }.to_json.freeze
      FORBIDDEN_HOST_BODY = { jsonrpc: '2.0', error: { code: -32_002, message: 'Host not allowed' }, id: nil }.to_json.freeze

      # @param app [#call] The next Rack app in the middleware stack
      # @param allowed_origins [Array<String>, #call, nil] Origin allow-list,
      #   or a callable returning one. A callable is resolved (and memoized)
      #   on the first guarded request, so an allow-list configured after the
      #   middleware was inserted — e.g. in `config/initializers/woods.rb`,
      #   which runs after Rails railtie initializers captured the middleware
      #   arguments — still takes effect (#183). Empty/nil falls back to
      #   {DEFAULT_ALLOWED}.
      # @param policy [OriginPolicy, nil] Captured policy also passed to the SDK
      # @param path [String, nil] When set, only requests whose PATH_INFO
      #   starts with this prefix are guarded — everything else passes
      #   straight through to the app. Nil (the default) guards every request.
      # @param enabled [#call, nil] Optional request-time predicate. When it
      #   returns falsy the request passes through unguarded. Nil (the
      #   default) means always guard.
      # Rails 6.0 forwards middleware options as a positional hash on Ruby 3.
      # Delegate to explicit keywords to preserve required/unknown option checks.
      def initialize(app, options = {}, **keywords)
        raise TypeError, 'middleware options must be a Hash' unless options.is_a?(Hash)

        initialize_options(app, **options, **keywords)
      end

      # Rack entry point. Out-of-scope requests (non-matching `path:` prefix
      # or a falsy `enabled:` predicate) pass through untouched.
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def call(env)
        return @app.call(env) unless guard?(env)

        origin = env['HTTP_ORIGIN']
        method = env['REQUEST_METHOD']
        host = env['HTTP_HOST']

        return forbidden unless policy.origin_allowed?(origin, host: host)
        return forbidden_host unless policy.host_allowed?(host)

        return preflight(origin) if method == 'OPTIONS'

        status, headers, body = @app.call(env)
        headers = cors_headers(origin).merge(headers) if origin
        [status, headers, body]
      end

      # The same lazily captured immutable policy is passed to the transport.
      # @return [OriginPolicy]
      def policy
        return @policy if @policy

        @policy_mutex.synchronize do
          @policy ||= OriginPolicy.new(allowed_origins: @allowed_source.call)
        end
      end

      private

      def initialize_options(app, allowed_origins: nil, path: nil, enabled: nil, policy: nil)
        @app = app
        @path = path
        @enabled = enabled
        @policy = policy
        @policy_mutex = Mutex.new
        @allowed_source = allowed_origins.respond_to?(:call) ? allowed_origins : -> { allowed_origins }
      end

      # @param env [Hash] Rack environment
      # @return [Boolean] whether this request falls under the guard
      def guard?(env)
        return false if @path && !env['PATH_INFO'].to_s.start_with?(@path)
        return false if @enabled && !@enabled.call

        true
      end

      def preflight(origin)
        headers = origin ? cors_headers(origin) : {}
        [204, headers, []]
      end

      def cors_headers(origin)
        {
          'access-control-allow-origin' => origin,
          'access-control-allow-methods' => ALLOWED_METHODS,
          'access-control-allow-headers' => ALLOWED_HEADERS,
          'access-control-expose-headers' => 'Mcp-Session-Id',
          'vary' => 'Origin'
        }
      end

      def forbidden
        [403, { 'content-type' => 'application/json' }, [FORBIDDEN_BODY]]
      end

      def forbidden_host
        [403, { 'content-type' => 'application/json' }, [FORBIDDEN_HOST_BODY]]
      end
    end
  end
end
