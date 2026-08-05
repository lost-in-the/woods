# frozen_string_literal: true

require 'json'
require 'rack/utils'

module Woods
  module MCP
    # Rack middleware that rejects requests lacking a matching bearer token.
    #
    # Uses Rack::Utils.secure_compare for constant-time comparison to avoid
    # leaking token bytes via response-time side channels.
    #
    # The token may be a String (validated at construction — the standalone
    # `woods-mcp-http` path) or a callable resolved on every request (the
    # Rails railtie path, where the token is typically set in
    # `config/initializers/woods.rb` and therefore does not exist yet when
    # the middleware is inserted — see #183). A deferred token that resolves
    # to nothing usable (nil, empty, or shorter than {MIN_TOKEN_LENGTH})
    # fails closed: every guarded request gets 401.
    class BearerAuth
      UNAUTHORIZED_BODY = { jsonrpc: '2.0', error: { code: -32_001, message: 'Unauthorized' }, id: nil }.to_json.freeze

      # Bearer tokens shorter than this are rejected at construction time.
      # Matches OWASP "session ID entropy" guidance (>= 128 bits ≈ 32 hex chars).
      MIN_TOKEN_LENGTH = 32

      # @param app [#call] The next Rack app in the middleware stack
      # @param token [String, #call] Bearer token, or a callable returning it.
      #   String tokens are validated eagerly (raises on nil/empty/short);
      #   callables are resolved on each request so a token configured after
      #   the middleware was inserted still takes effect.
      # @param path [String, nil] When set, only requests whose PATH_INFO
      #   starts with this prefix are guarded — everything else passes
      #   straight through to the app. Nil (the default) guards every request.
      # @param enabled [#call, nil] Optional request-time predicate. When it
      #   returns falsy the request passes through unguarded. Nil (the
      #   default) means always guard.
      def initialize(app, token:, path: nil, enabled: nil)
        @app = app
        @path = path
        @enabled = enabled
        @warned_unusable_token = false

        if token.respond_to?(:call)
          @token_source = token
        else
          validate_static_token!(token)
          static_token = token.to_s
          @token_source = -> { static_token }
        end
      end

      # Rack entry point. Out-of-scope requests (non-matching `path:` prefix
      # or a falsy `enabled:` predicate) pass through untouched; guarded
      # requests require a matching `Authorization: Bearer <token>` header.
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def call(env)
        return @app.call(env) unless guard?(env)

        expected = resolve_token
        header = env['HTTP_AUTHORIZATION'].to_s
        presented = header.start_with?('Bearer ') ? header.sub(/\ABearer /, '') : nil

        if expected && presented && Rack::Utils.secure_compare(expected, presented)
          @app.call(env)
        else
          unauthorized
        end
      end

      private

      # @param env [Hash] Rack environment
      # @return [Boolean] whether this request falls under the guard
      def guard?(env)
        return false if @path && !env['PATH_INFO'].to_s.start_with?(@path)
        return false if @enabled && !@enabled.call

        true
      end

      # Resolve the expected token for this request. Static tokens were
      # validated at construction; deferred tokens are re-checked here and
      # an unusable value fails closed (nil => 401 for every request).
      #
      # @return [String, nil]
      def resolve_token
        token = @token_source.call.to_s
        return token if token.length >= MIN_TOKEN_LENGTH

        warn_unusable_token(token)
        nil
      end

      # @param token [String] the eagerly-supplied token
      # @raise [ArgumentError] on nil, empty, or too-short tokens
      def validate_static_token!(token)
        raise ArgumentError, 'token must be a non-empty string' if token.nil? || token.empty?
        return unless token.to_s.length < MIN_TOKEN_LENGTH

        raise ArgumentError,
              "bearer token must be at least #{MIN_TOKEN_LENGTH} characters " \
              "(got #{token.to_s.length}); generate with `SecureRandom.hex(32)`"
      end

      # Warn (once per instance) that a deferred token is unusable, so the
      # resulting wall of 401s is explicable from the logs.
      #
      # @param token [String] the resolved (unusable) token
      # @return [void]
      def warn_unusable_token(token)
        return if @warned_unusable_token

        @warned_unusable_token = true
        reason = if token.empty?
                   'no bearer token is configured'
                 else
                   "the configured bearer token is shorter than #{MIN_TOKEN_LENGTH} characters"
                 end
        warn "[Woods::MCP::BearerAuth] refusing guarded requests (401): #{reason}. " \
             'Set a 32+ character token (e.g. `SecureRandom.hex(32)`).'
      end

      # @return [Array] 401 Rack response triple
      def unauthorized
        [401,
         { 'content-type' => 'application/json', 'www-authenticate' => 'Bearer realm="woods-mcp-http"' },
         [UNAUTHORIZED_BODY]]
      end
    end
  end
end
