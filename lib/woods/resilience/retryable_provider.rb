# frozen_string_literal: true

require_relative '../embedding/provider'
require_relative '../retry_after'
require_relative 'circuit_breaker'

module Woods
  module Resilience
    # Wraps an embedding provider with retry logic and optional circuit breaker.
    #
    # Transparently retries transient failures with exponential backoff.
    # When a circuit breaker is provided, all calls are routed through it,
    # and {CircuitOpenError} is never retried.
    #
    # @example Without circuit breaker
    #   retryable = RetryableProvider.new(provider: ollama_provider, max_retries: 3)
    #   vector = retryable.embed("some text")
    #
    # @example With circuit breaker
    #   breaker = CircuitBreaker.new(threshold: 5, reset_timeout: 60)
    #   retryable = RetryableProvider.new(
    #     provider: ollama_provider,
    #     max_retries: 3,
    #     circuit_breaker: breaker
    #   )
    #   vector = retryable.embed("some text")
    class RetryableProvider
      include Woods::Embedding::Provider::Interface

      # @return [#embed, #embed_batch] the wrapped (raw) embedding provider.
      #   Exposed so builders can reach the concrete class for tokenizer
      #   calibration (see Builder#chars_per_token_for) without unwinding
      #   the resilience stack by hand.
      attr_reader :provider

      # @return [CircuitBreaker, nil] the breaker guarding this provider's
      #   calls, or nil when none was configured. Per-instance by design —
      #   never share one breaker across unrelated components.
      attr_reader :circuit_breaker

      # @param provider [#embed, #embed_batch, #dimensions, #model_name] The underlying embedding provider
      # @param max_retries [Integer] Maximum number of retry attempts
      # @param circuit_breaker [CircuitBreaker, nil] Optional circuit breaker instance
      def initialize(provider:, max_retries: 3, circuit_breaker: nil)
        @provider = provider
        @max_retries = max_retries
        @circuit_breaker = circuit_breaker
      end

      # Embed a single text string with retry logic.
      #
      # @param text [String] the text to embed
      # @return [Array<Float>] the embedding vector
      # @raise [CircuitOpenError] if the circuit breaker is open
      # @raise [StandardError] if all retries are exhausted
      def embed(text)
        with_retries { call_provider { @provider.embed(text) } }
      end

      # Embed multiple texts with retry logic.
      #
      # @param texts [Array<String>] the texts to embed
      # @return [Array<Array<Float>>] array of embedding vectors
      # @raise [CircuitOpenError] if the circuit breaker is open
      # @raise [StandardError] if all retries are exhausted
      def embed_batch(texts)
        with_retries { call_provider { @provider.embed_batch(texts) } }
      end

      # Return the dimensionality of the embedding vectors.
      #
      # @return [Integer] number of dimensions
      def dimensions
        @provider.dimensions
      end

      # Return the name of the embedding model.
      #
      # @return [String] model name
      def model_name
        @provider.model_name
      end

      # Delegate the per-provider input cap. The retry wrapper does not
      # change the provider's budget, so just hand through whatever the
      # inner provider reports. Without this, `respond_to?` returns true
      # via Interface but the call raises NotImplementedError.
      #
      # @return [Integer, nil]
      def max_input_tokens
        return @provider.max_input_tokens if @provider.respond_to?(:max_input_tokens)

        nil
      end

      # Maximum backoff delay in seconds. Without a cap, attempts 8+ sleep
      # longer than most service-level timeouts (>25s) and compound retry
      # storms across correlated workers.
      MAX_BACKOFF_SECONDS = 30.0

      # Base multiplier for exponential backoff. Delay is roughly
      # `BACKOFF_BASE * 2**attempt` with full jitter applied on top.
      BACKOFF_BASE = 0.1

      # Upper bound honored for a server-supplied +Retry-After+. Bounds a
      # hostile or misconfigured header (e.g. an HTTP-date hours away) so a
      # single throttled call cannot stall the embed pipeline indefinitely;
      # real rate-limit windows sit well under this.
      MAX_RETRY_AFTER_SECONDS = 120.0

      private

      # Execute a block with retry logic, exponential backoff, and jitter.
      #
      # Argument errors surface immediately (non-retryable — they indicate
      # a programming mistake or invalid input, not a transient failure).
      # Errors carrying a non-retryable HTTP status (see {#retryable_error?})
      # also surface immediately — retrying a 401 only delays the real error.
      #
      # @yield The block to execute
      # @return [Object] The return value of the block
      # @raise [CircuitOpenError] immediately without retrying
      # @raise [ArgumentError] immediately without retrying
      # @raise [StandardError] the last error if all retries are exhausted,
      #   or the first error when it is classified non-retryable
      def with_retries
        attempt = 0
        begin
          attempt += 1
          yield
        rescue CircuitOpenError, ArgumentError
          raise
        rescue StandardError => e
          raise e if attempt > @max_retries || !retryable_error?(e)

          sleep(retry_delay(e, attempt))
          retry
        end
      end

      # Decide whether an error is worth retrying.
      #
      # Errors that expose an HTTP status (duck-typed on +#http_status+ —
      # {Woods::Embedding::Provider::RequestError} is the canonical shape)
      # are classified precisely: 429 (rate limit), 408 (request timeout),
      # and 5xx are transient; every other 4xx is a request or credential
      # problem no retry can fix, so burning the retry budget (and sleeping
      # between attempts) only postpones the real error. Status-less errors
      # — connection resets, socket timeouts, legacy Woods::Error strings —
      # keep the historical retry-everything behavior.
      #
      # @param error [StandardError]
      # @return [Boolean] true when the error should be retried
      def retryable_error?(error)
        status = error.respond_to?(:http_status) ? error.http_status : nil
        return true unless status.is_a?(Integer)

        status == 429 || status == 408 || status >= 500
      end

      # Seconds to sleep before the next retry. A server-supplied
      # +Retry-After+ (parsed via {Woods::RetryAfter}, which handles both
      # the delta-seconds and HTTP-date forms) takes precedence over the
      # local backoff schedule, capped at {MAX_RETRY_AFTER_SECONDS};
      # without one, full-jitter exponential backoff applies.
      #
      # @param error [StandardError] the error that triggered the retry
      # @param attempt [Integer] 1-based attempt counter
      # @return [Float] seconds to sleep before the next retry
      def retry_delay(error, attempt)
        fallback = backoff_seconds(attempt)
        header = error.respond_to?(:retry_after) ? error.retry_after : nil
        return fallback if header.nil?

        [RetryAfter.seconds(header, fallback: fallback), MAX_RETRY_AFTER_SECONDS].min
      end

      # Full-jitter exponential backoff with a hard cap. See "Exponential
      # Backoff and Jitter", AWS Architecture Blog (Marc Brooker, 2015):
      # a uniformly random delay in [0, base*2**attempt] de-correlates
      # competing retry waves.
      #
      # @param attempt [Integer] 1-based attempt counter
      # @return [Float] seconds to sleep before the next retry
      def backoff_seconds(attempt)
        ceiling = [BACKOFF_BASE * (2**attempt), MAX_BACKOFF_SECONDS].min
        rand * ceiling
      end

      # Route a call through the circuit breaker if one is configured.
      #
      # @yield The block to execute
      # @return [Object] The return value of the block
      def call_provider(&block)
        if @circuit_breaker
          @circuit_breaker.call(&block)
        else
          block.call
        end
      end
    end
  end
end
