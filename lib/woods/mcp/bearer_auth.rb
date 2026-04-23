# frozen_string_literal: true

require 'rack/utils'

module Woods
  module MCP
    # Rack middleware that rejects requests lacking a matching bearer token.
    #
    # Uses Rack::Utils.secure_compare for constant-time comparison to avoid
    # leaking token bytes via response-time side channels.
    class BearerAuth
      UNAUTHORIZED_BODY = { jsonrpc: '2.0', error: { code: -32_001, message: 'Unauthorized' }, id: nil }.to_json.freeze

      # Bearer tokens shorter than this are rejected at construction time.
      # Matches OWASP "session ID entropy" guidance (>= 128 bits ≈ 32 hex chars).
      MIN_TOKEN_LENGTH = 32

      def initialize(app, token:)
        raise ArgumentError, 'token must be a non-empty string' if token.nil? || token.empty?
        if token.to_s.length < MIN_TOKEN_LENGTH
          raise ArgumentError,
                "bearer token must be at least #{MIN_TOKEN_LENGTH} characters " \
                "(got #{token.to_s.length}); generate with `SecureRandom.hex(32)`"
        end

        @app = app
        @token = token.to_s
      end

      def call(env)
        header = env['HTTP_AUTHORIZATION'].to_s
        presented = header.start_with?('Bearer ') ? header.sub(/\ABearer /, '') : nil

        if presented && Rack::Utils.secure_compare(@token, presented)
          @app.call(env)
        else
          [401,
           { 'content-type' => 'application/json', 'www-authenticate' => 'Bearer realm="woods-mcp-http"' },
           [UNAUTHORIZED_BODY]]
        end
      end
    end
  end
end
