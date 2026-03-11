# frozen_string_literal: true

require_relative '../embedding/provider'
require_relative 'circuit_breaker'

module CodebaseIndex
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
      include CodebaseIndex::Embedding::Provider::Interface

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

      private

      # Execute a block with retry logic and exponential backoff.
      #
      # @yield The block to execute
      # @return [Object] The return value of the block
      # @raise [CircuitOpenError] immediately without retrying
      # @raise [StandardError] the last error if all retries are exhausted
      def with_retries
        attempt = 0
        begin
          attempt += 1
          yield
        rescue CircuitOpenError
          raise
        rescue StandardError => e
          raise e if attempt > @max_retries

          sleep((2**attempt) * 0.1)
          retry
        end
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
