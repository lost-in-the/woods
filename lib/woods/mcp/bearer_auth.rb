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

      def initialize(app, token:)
        raise ArgumentError, 'token must be a non-empty string' if token.nil? || token.empty?

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
