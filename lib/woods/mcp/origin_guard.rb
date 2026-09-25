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
    # Cross-origin entries match exact origins, with equivalent default ports.
    # Portless entries also permit same-authority requests on other ports.
    #
    # Also answers CORS preflight (OPTIONS) with the matching allow-list.
    class OriginGuard
      DEFAULT_ALLOWED = OriginPolicy::DEFAULT_ORIGINS

      # Hosts that always pass the Host-header check even without an explicit
      # allow-list entry — they resolve to loopback by definition and cannot
      # be rebound to an attacker-controlled address.
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

      ALLOWED_METHODS = 'GET, POST, DELETE, OPTIONS'
      ALLOWED_HEADERS = 'Authorization, Content-Type, MCP-Protocol-Version, Mcp-Session-Id'

      # Response bodies are emitted as constants so the rejected Origin /
      # Host value is NEVER echoed back to the caller — preventing a
      # stored-XSS / log-injection surface where an attacker-supplied
      # header ended up embedded in the JSON error.
      FORBIDDEN_BODY = { jsonrpc: '2.0', error: { code: -32_002, message: 'Origin not allowed' }, id: nil }.to_json.freeze
      FORBIDDEN_HOST_BODY = { jsonrpc: '2.0', error: { code: -32_002, message: 'Host not allowed' }, id: nil }.to_json.freeze

      attr_reader :policy

      # Rails 6 passes middleware keyword options as a positional Hash on Ruby 3.
      def initialize(app, options = {}, **keywords)
        raise TypeError, 'middleware options must be a Hash' unless options.is_a?(Hash)

        initialize_options(app, **options, **keywords)
      end

      def initialize_options(app, allowed_origins: nil, policy: nil, path: nil)
        @app = app
        @path = path
        origins = allowed_origins.respond_to?(:call) ? allowed_origins.call : allowed_origins
        @policy = policy || OriginPolicy.new(allowed_origins: origins)
      end
      private :initialize_options

      def call(env)
        return @app.call(env) if @path && !env['PATH_INFO'].to_s.start_with?(@path)

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

      private

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
