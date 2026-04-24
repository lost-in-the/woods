# frozen_string_literal: true

require 'json'

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
    # Port-matching: an allow-list entry WITHOUT a port (`http://localhost`)
    # matches that host on any port. An entry WITH a port (`http://localhost:3000`)
    # requires an exact port match. Specify explicit ports when port isolation
    # matters.
    #
    # Also answers CORS preflight (OPTIONS) with the matching allow-list.
    class OriginGuard
      DEFAULT_ALLOWED = %w[
        http://localhost http://127.0.0.1 http://[::1]
        https://localhost https://127.0.0.1 https://[::1]
      ].freeze

      ALLOWED_METHODS = 'GET, POST, DELETE, OPTIONS'
      ALLOWED_HEADERS = 'Authorization, Content-Type, Mcp-Session-Id'

      FORBIDDEN_BODY = { jsonrpc: '2.0', error: { code: -32_002, message: 'Origin not allowed' }, id: nil }.to_json.freeze

      def initialize(app, allowed_origins: nil)
        @app = app
        @allowed = Array(allowed_origins).compact.reject { |o| o.to_s.strip.empty? }.map { |o| normalize(o) }
        @allowed = DEFAULT_ALLOWED.dup if @allowed.empty?
      end

      def call(env)
        origin = env['HTTP_ORIGIN']
        method = env['REQUEST_METHOD']

        return forbidden if origin && !origin_allowed?(origin)

        return preflight(origin) if method == 'OPTIONS'

        status, headers, body = @app.call(env)
        headers = cors_headers(origin).merge(headers) if origin && origin_allowed?(origin)
        [status, headers, body]
      end

      private

      def normalize(origin)
        origin.to_s.sub(%r{/\z}, '').downcase
      end

      def origin_allowed?(origin)
        return false if origin.match?(/[[:cntrl:]]/)

        @allowed.include?(normalize(origin)) || @allowed.include?(normalize(origin).sub(/:\d+\z/, ''))
      end

      def preflight(origin)
        headers = origin && origin_allowed?(origin) ? cors_headers(origin) : {}
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
    end
  end
end
