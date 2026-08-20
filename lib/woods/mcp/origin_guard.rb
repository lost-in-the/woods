# frozen_string_literal: true

require 'json'

require_relative '../util/host_guard'

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
      # @param path [String, nil] When set, only requests whose PATH_INFO
      #   starts with this prefix are guarded — everything else passes
      #   straight through to the app. Nil (the default) guards every request.
      # @param enabled [#call, nil] Optional request-time predicate. When it
      #   returns falsy the request passes through unguarded. Nil (the
      #   default) means always guard.
      def initialize(app, allowed_origins: nil, path: nil, enabled: nil)
        @app = app
        @path = path
        @enabled = enabled
        if allowed_origins.respond_to?(:call)
          @allowed_source = allowed_origins
        else
          build_allow_list(allowed_origins)
        end
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

        return forbidden if origin && !origin_allowed?(origin)
        return forbidden_host if host && !host_allowed?(host)

        return preflight(origin) if method == 'OPTIONS'

        status, headers, body = @app.call(env)
        headers = cors_headers(origin).merge(headers) if origin && origin_allowed?(origin)
        [status, headers, body]
      end

      private

      # @param env [Hash] Rack environment
      # @return [Boolean] whether this request falls under the guard
      def guard?(env)
        return false if @path && !env['PATH_INFO'].to_s.start_with?(@path)
        return false if @enabled && !@enabled.call

        true
      end

      # Normalize a raw allow-list into `@allowed` + `@allowed_hosts`.
      #
      # @param origins [Array<String>, nil]
      # @return [Array<String>] the normalized allow-list
      def build_allow_list(origins)
        allowed = Array(origins).compact.reject { |o| o.to_s.strip.empty? }.map { |o| normalize(o) }
        allowed = DEFAULT_ALLOWED.dup if allowed.empty?
        @allowed_hosts = allowed.map { |o| extract_host(o) }.compact.uniq
        @allowed = allowed
      end

      # The allow-list, resolving a deferred source on first use. Memoized —
      # configuration is settled by the time the first request arrives.
      #
      # @return [Array<String>]
      def allowed
        @allowed || build_allow_list(@allowed_source.call)
      end

      # @return [Array<String>] hosts extracted from the allow-list
      def allowed_hosts
        allowed
        @allowed_hosts
      end

      def normalize(origin)
        origin.to_s.sub(%r{/\z}, '').downcase
      end

      def extract_host(origin)
        host = origin.to_s.sub(%r{\Ahttps?://}, '').sub(%r{/.*\z}, '').downcase
        host.empty? ? nil : host
      end

      def host_allowed?(host)
        # Canonicalize (strip port, trailing dot, IPv6 brackets) via the
        # shared helper so Qdrant and OriginGuard stay in sync on bypass
        # notations. `normalized` keeps the port for literal allow-list
        # lookups; `bare` drops it for loopback matching.
        normalized = host.to_s.downcase.sub(/\.\z/, '')
        bare = Util::HostGuard.canonicalize(host)

        # Reject non-canonical numeric hosts. Net::HTTP / getaddrinfo
        # would happily resolve `0x7f000001` or `2130706433` to 127.0.0.1,
        # bypassing the loopback allow-list.
        return false if Util::HostGuard.suspicious_numeric_host?(bare)

        return true if LOOPBACK_HOSTS.include?(bare)

        allowed_hosts.include?(normalized) || allowed_hosts.include?(bare)
      end

      def origin_allowed?(origin)
        return false if origin.match?(/[[:cntrl:]]/)

        allowed.include?(normalize(origin)) || allowed.include?(normalize(origin).sub(/:\d+\z/, ''))
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

      def forbidden_host
        [403, { 'content-type' => 'application/json' }, [FORBIDDEN_HOST_BODY]]
      end
    end
  end
end
