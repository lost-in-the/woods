# frozen_string_literal: true

module CodebaseIndex
  module CostModel
    # Unified cost estimator that combines embedding, storage, and query costs
    # into a single breakdown for a given configuration.
    #
    # @example
    #   estimate = Estimator.new(
    #     units: 500,
    #     chunk_multiplier: 2.5,
    #     embedding_provider: :openai_small,
    #     dimensions: 1536,
    #     daily_queries: 100
    #   )
    #   estimate.full_index_cost    # => 0.01125
    #   estimate.monthly_query_cost # => 0.006
    #   estimate.storage_bytes      # => 9_984_000
    #   estimate.to_h               # => { full_index_cost: ..., ... }
    #
    class Estimator
      # @return [Integer] Number of extracted units
      attr_reader :units

      # @return [Float] Average chunks per unit
      attr_reader :chunk_multiplier

      # @return [Symbol] Embedding provider key
      attr_reader :embedding_provider

      # @return [Integer] Embedding vector dimensions
      attr_reader :dimensions

      # @return [Integer] Number of retrieval queries per day
      attr_reader :daily_queries

      # @param units [Integer] Number of extracted units
      # @param chunk_multiplier [Float] Average chunks per unit (default 2.5)
      # @param embedding_provider [Symbol] Provider key from {ProviderPricing}
      # @param dimensions [Integer, nil] Vector dimensions (defaults to provider default)
      # @param daily_queries [Integer] Retrieval queries per day (default 100)
      def initialize(units:, embedding_provider:, chunk_multiplier: 2.5, dimensions: nil, daily_queries: 100)
        @units = units
        @chunk_multiplier = chunk_multiplier
        @embedding_provider = embedding_provider
        @dimensions = dimensions || ProviderPricing.default_dimensions(embedding_provider)
        @daily_queries = daily_queries

        @embedding_cost = EmbeddingCost.new(provider: embedding_provider)
        @storage_cost = StorageCost.new(dimensions: @dimensions)
      end

      # Cost to embed the full codebase index.
      #
      # @return [Float] Cost in USD
      def full_index_cost
        @embedding_cost.full_index_cost(units: units, chunk_multiplier: chunk_multiplier)
      end

      # Cost to re-embed a single merge (default 5 changed units).
      #
      # @param changed_units [Integer] Units changed per merge (default 5)
      # @return [Float] Cost in USD
      def incremental_per_merge_cost(changed_units: 5)
        @embedding_cost.incremental_cost(changed_units: changed_units, chunk_multiplier: chunk_multiplier)
      end

      # Monthly cost for query-time embedding.
      #
      # @return [Float] Cost in USD per month
      def monthly_query_cost
        @embedding_cost.monthly_query_cost(daily_queries: daily_queries)
      end

      # Yearly embedding cost from incremental re-indexing.
      #
      # @param merges_per_year [Integer] Merges per year (default 2400)
      # @return [Float] Cost in USD per year
      def yearly_incremental_cost(merges_per_year: 2400)
        @embedding_cost.yearly_incremental_cost(
          merges_per_year: merges_per_year,
          chunk_multiplier: chunk_multiplier
        )
      end

      # Total number of chunks for the codebase.
      #
      # @return [Integer]
      def total_chunks
        @total_chunks ||= (units * chunk_multiplier).ceil
      end

      # Total storage in bytes for vector data.
      #
      # @return [Integer]
      def storage_bytes
        @storage_cost.storage_bytes(chunks: total_chunks)
      end

      # Total storage in megabytes for vector data.
      #
      # @return [Float]
      def storage_mb
        @storage_cost.storage_mb(chunks: total_chunks)
      end

      # Full cost breakdown as a Hash.
      #
      # @return [Hash{Symbol => Numeric}]
      def to_h
        {
          full_index_cost: full_index_cost,
          incremental_per_merge_cost: incremental_per_merge_cost,
          monthly_query_cost: monthly_query_cost,
          yearly_incremental_cost: yearly_incremental_cost,
          storage_bytes: storage_bytes,
          storage_mb: storage_mb,
          total_chunks: total_chunks,
          units: units,
          chunk_multiplier: chunk_multiplier,
          embedding_provider: embedding_provider,
          dimensions: dimensions,
          daily_queries: daily_queries
        }
      end
    end
  end
end
