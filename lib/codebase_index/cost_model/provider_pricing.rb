# frozen_string_literal: true

module CodebaseIndex
  module CostModel
    # Frozen pricing data for embedding providers.
    #
    # Costs are expressed as dollars per 1 million tokens, sourced from
    # BACKEND_MATRIX.md. Each provider is identified by a Symbol key.
    #
    # @example
    #   ProviderPricing.cost_per_million(:openai_small) # => 0.02
    #   ProviderPricing.providers                        # => [:openai_small, ...]
    #
    module ProviderPricing
      # Cost per 1 million tokens, in USD.
      #
      # @return [Hash{Symbol => Float}]
      COSTS_PER_MILLION_TOKENS = {
        openai_small: 0.02,
        openai_large: 0.13,
        voyage_code3: 0.06,
        ollama: 0.00
      }.freeze

      # Default embedding dimensions per provider.
      #
      # @return [Hash{Symbol => Integer}]
      DEFAULT_DIMENSIONS = {
        openai_small: 1536,
        openai_large: 3072,
        voyage_code3: 1024,
        ollama: 768
      }.freeze

      # Look up the cost per 1M tokens for a provider.
      #
      # @param provider [Symbol] Provider key (e.g. :openai_small)
      # @return [Float] Cost in USD per 1M tokens
      # @raise [ArgumentError] if provider is unknown
      def self.cost_per_million(provider)
        COSTS_PER_MILLION_TOKENS.fetch(provider) do
          raise ArgumentError, "Unknown embedding provider: #{provider.inspect}. " \
                               "Valid providers: #{providers.join(', ')}"
        end
      end

      # Look up the default dimensions for a provider.
      #
      # @param provider [Symbol] Provider key
      # @return [Integer] Default embedding dimensions
      # @raise [ArgumentError] if provider is unknown
      def self.default_dimensions(provider)
        DEFAULT_DIMENSIONS.fetch(provider) do
          raise ArgumentError, "Unknown embedding provider: #{provider.inspect}. " \
                               "Valid providers: #{providers.join(', ')}"
        end
      end

      # List all known provider keys.
      #
      # @return [Array<Symbol>]
      def self.providers
        COSTS_PER_MILLION_TOKENS.keys
      end
    end
  end
end
