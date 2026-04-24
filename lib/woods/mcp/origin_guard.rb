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
    # Host header validation defends against the residual DNS-rebinding surface:
    # an attacker who controls a hostname they can point at the server's IP can
    # pass the Origin check (the browser sends their origin, which we might
    # allow-list for some deployments) while Host carries their hostname. By
    # also requiring Host to appear in the allow-list (or to be a loopback
    # address), we close that gap even when Rails is bound to 0.0.0.0.
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
      ALLOWED_HEADERS = 'Authorization, Content-Type, Mcp-Session-Id'

      def initialize(app, allowed_origins: nil)
        @app = app
        @allowed = Array(allowed_origins).compact.reject { |o| o.to_s.strip.empty? }.map { |o| normalize(o) }
        @allowed = DEFAULT_ALLOWED.dup if @allowed.empty?
        @allowed_hosts = @allowed.map { |o| extract_host(o) }.compact.uniq
      end

      def call(env)
        origin = env['HTTP_ORIGIN']
        method = env['REQUEST_METHOD']
        host = env['HTTP_HOST']

        return forbidden(origin) if origin && !origin_allowed?(origin)
        return forbidden_host(host) if host && !host_allowed?(host)

        return preflight(origin) if method == 'OPTIONS'

        status, headers, body = @app.call(env)
        headers = cors_headers(origin).merge(headers) if origin && origin_allowed?(origin)
        [status, headers, body]
      end

      private

      def normalize(origin)
        origin.to_s.sub(%r{/\z}, '').downcase
      end

      def extract_host(origin)
        host = origin.to_s.sub(%r{\Ahttps?://}, '').sub(%r{/.*\z}, '').downcase
        host.empty? ? nil : host
      end

      # Numeric host forms that resolve to loopback / private space via
      # `getaddrinfo` but evade literal-string matches on `127.0.0.1` /
      # `localhost`. We reject them outright rather than try to canonicalize
      # every notation — the OS will still resolve them, but browsers and
      # stdio clients never need them.
      NUMERIC_HOST_BYPASS = Regexp.union(
        /\A0x[0-9a-f]+\z/,           # hex: `0x7f000001`
        /\A\d+\z/,                   # bare integer: `2130706433`
        /\A0[0-7]+\z/,               # bare octal: `017700000001`
        /\A\d+\.\d+\z/,              # short-form two-part: `127.1`
        /\A\d+\.\d+\.\d+\z/          # short-form three-part: `127.0.1`
      ).freeze
      private_constant :NUMERIC_HOST_BYPASS

      def host_allowed?(host)
        # Strip port and trailing dot (FQDN form — `localhost.` is
        # equivalent to `localhost` in DNS but would slip a literal-list
        # check) before checking against loopback + allow-list.
        normalized = host.to_s.downcase.sub(/\.\z/, '')
        bare = normalized.sub(/:\d+\z/, '').sub(/\.\z/, '')

        # Reject non-canonical numeric hosts. Net::HTTP / getaddrinfo
        # would happily resolve `0x7f000001` or `2130706433` to 127.0.0.1,
        # bypassing the loopback allow-list.
        return false if suspicious_numeric_host?(bare)

        return true if LOOPBACK_HOSTS.include?(bare)

        @allowed_hosts.include?(normalized) || @allowed_hosts.include?(bare)
      end

      def suspicious_numeric_host?(bare)
        return true if bare.match?(NUMERIC_HOST_BYPASS)

        # Four-octet dotted-decimal is legitimate unless an octet carries
        # a leading zero (octal interpretation in getaddrinfo).
        four_octet = bare.match(/\A(\d+)\.(\d+)\.(\d+)\.(\d+)\z/)
        return false unless four_octet

        four_octet.captures.any? { |octet| octet.length > 1 && octet.start_with?('0') }
      end

      def origin_allowed?(origin)
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

      def forbidden(origin)
        body = { jsonrpc: '2.0', error: { code: -32_002, message: "Origin not allowed: #{origin}" }, id: nil }.to_json
        [403, { 'content-type' => 'application/json' }, [body]]
      end

      def forbidden_host(host)
        body = { jsonrpc: '2.0', error: { code: -32_002, message: "Host not allowed: #{host}" }, id: nil }.to_json
        [403, { 'content-type' => 'application/json' }, [body]]
      end
    end
  end
end
