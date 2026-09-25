# frozen_string_literal: true

require 'json'
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

      # Rails 6 forwards middleware keywords as a positional options Hash.
      def initialize(app, options = {}, **keywords)
        raise TypeError, 'middleware options must be a Hash' unless options.is_a?(Hash)

        initialize_options(app, **options, **keywords)
      end

      def initialize_options(app, token:, path: nil)
        @app = app
        @path = path
        @token = token
        validate_token!(token) unless token.respond_to?(:call)
        @token = token.to_s unless token.respond_to?(:call)
      end
      private :initialize_options

      def call(env)
        return @app.call(env) if @path && !env['PATH_INFO'].to_s.start_with?(@path)

        token = @token.respond_to?(:call) ? @token.call : @token
        header = env['HTTP_AUTHORIZATION'].to_s
        presented = header.b.match?(/\A[Bb][Ee][Aa][Rr][Ee][Rr] /) ? header.byteslice(7..) : nil

        if token.is_a?(String) && token.length >= MIN_TOKEN_LENGTH && presented &&
           Rack::Utils.secure_compare(token, presented)
          @app.call(env)
        else
          [401,
           { 'content-type' => 'application/json', 'www-authenticate' => 'Bearer realm="woods-mcp-http"' },
           [UNAUTHORIZED_BODY]]
        end
      end

      private

      def validate_token!(token)
        raise ArgumentError, 'token must be a non-empty string' if token.nil? || token.to_s.empty?
        return unless token.to_s.length < MIN_TOKEN_LENGTH

        raise ArgumentError,
              "bearer token must be at least #{MIN_TOKEN_LENGTH} characters " \
              "(got #{token.to_s.length}); generate with `SecureRandom.hex(32)`"
      end
    end
  end
end
