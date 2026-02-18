# frozen_string_literal: true

module CodebaseIndex
  module CostModel
    # Calculates embedding costs for full-index, incremental, and query-time
    # scenarios using the token-based pricing from {ProviderPricing}.
    #
    # The cost model uses a constant of 450 tokens per chunk, derived from the
    # BACKEND_MATRIX.md tables (e.g. 500 units × 2.5 chunks = 1250 chunks × 450 = 562K tokens).
    #
    # @example
    #   calc = EmbeddingCost.new(provider: :openai_small)
    #   calc.full_index_cost(units: 500, chunk_multiplier: 2.5) # => 0.01125
    #
    class EmbeddingCost
      # Average tokens per chunk after hierarchical chunking with context prefix.
      TOKENS_PER_CHUNK = 450

      # Average tokens per retrieval query.
      TOKENS_PER_QUERY = 100

      # @param provider [Symbol] Embedding provider key from {ProviderPricing}
      def initialize(provider:)
        @cost_per_million = ProviderPricing.cost_per_million(provider)
      end

      # Cost to embed the full codebase index.
      #
      # @param units [Integer] Number of extracted units
      # @param chunk_multiplier [Float] Average chunks per unit (default 2.5)
      # @return [Float] Cost in USD
      def full_index_cost(units:, chunk_multiplier: 2.5)
        tokens = total_tokens(units, chunk_multiplier)
        token_cost(tokens)
      end

      # Cost to re-embed changed units from a single merge.
      #
      # @param changed_units [Integer] Number of units changed (default 5)
      # @param chunk_multiplier [Float] Average chunks per unit (default 2.5)
      # @return [Float] Cost in USD
      def incremental_cost(changed_units: 5, chunk_multiplier: 2.5)
        tokens = total_tokens(changed_units, chunk_multiplier)
        token_cost(tokens)
      end

      # Monthly cost for query-time embedding.
      #
      # @param daily_queries [Integer] Number of queries per day
      # @return [Float] Cost in USD per month
      def monthly_query_cost(daily_queries:)
        monthly_tokens = daily_queries * 30 * TOKENS_PER_QUERY
        token_cost(monthly_tokens)
      end

      # Yearly embedding cost from incremental re-indexing.
      #
      # @param merges_per_year [Integer] Number of merges per year (default 2400)
      # @param changed_units_per_merge [Integer] Units changed per merge (default 5)
      # @param chunk_multiplier [Float] Average chunks per unit (default 2.5)
      # @return [Float] Cost in USD per year
      def yearly_incremental_cost(merges_per_year: 2400, changed_units_per_merge: 5, chunk_multiplier: 2.5)
        tokens_per_merge = total_tokens(changed_units_per_merge, chunk_multiplier)
        token_cost(tokens_per_merge * merges_per_year)
      end

      # Total tokens for a given number of units and chunk multiplier.
      #
      # @param units [Integer] Number of units
      # @param chunk_multiplier [Float] Chunks per unit
      # @return [Integer] Total embedding tokens
      def total_tokens(units, chunk_multiplier)
        chunks = (units * chunk_multiplier).ceil
        chunks * TOKENS_PER_CHUNK
      end

      private

      # Convert token count to cost in USD.
      #
      # @param tokens [Numeric] Number of tokens
      # @return [Float] Cost in USD
      def token_cost(tokens)
        (tokens.to_f / 1_000_000) * @cost_per_million
      end
    end
  end
end
