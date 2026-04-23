# frozen_string_literal: true

require 'digest'
require_relative 'cache_store'

module Woods
  module Cache
    # Decorator that wraps an embedding provider with cache-through logic.
    #
    # Implements the same {Embedding::Provider::Interface} so it can be
    # injected transparently in place of the real provider. On cache hit,
    # the expensive API call (OpenAI, Ollama) is skipped entirely.
    #
    # @example
    #   real_provider = Embedding::Provider::OpenAI.new(api_key: key)
    #   cached = CachedEmbeddingProvider.new(provider: real_provider, cache_store: store)
    #   cached.embed("How does User work?")  # API call + cache write
    #   cached.embed("How does User work?")  # cache hit, no API call
    #
    class CachedEmbeddingProvider
      include Embedding::Provider::Interface

      # @param provider [Embedding::Provider::Interface] The real embedding provider
      # @param cache_store [CacheStore] Cache backend instance
      # @param ttl [Integer] TTL for cached embeddings in seconds
      def initialize(provider:, cache_store:, ttl: DEFAULT_TTLS[:embeddings])
        @provider = provider
        @cache_store = cache_store
        @ttl = ttl
      end

      # Embed a single text, returning a cached vector when available.
      #
      # @param text [String] Text to embed
      # @return [Array<Float>] Embedding vector
      def embed(text)
        key = embedding_key(text)
        @cache_store.fetch(key, ttl: @ttl) { @provider.embed(text) }
      end

      # Embed a batch of texts, using cached vectors for any previously seen texts.
      #
      # Only texts that are not already cached are sent to the real provider.
      # Results are merged back in original order.
      #
      # @param texts [Array<String>] Texts to embed
      # @return [Array<Array<Float>>] Embedding vectors (same order as input)
      def embed_batch(texts)
        results, misses, miss_indices = partition_cached(texts)

        if misses.any?
          fresh_vectors = @provider.embed_batch(misses)
          misses.each_with_index do |text, i|
            results[miss_indices[i]] = fresh_vectors[i]
            begin
              @cache_store.write(embedding_key(text), fresh_vectors[i], ttl: @ttl)
            rescue StandardError => e
              warn("[Woods] CachedEmbeddingProvider cache write failed: #{e.message}")
            end
          end
        end

        results
      end

      # Delegate dimensions to the underlying provider.
      #
      # @return [Integer]
      def dimensions
        @provider.dimensions
      end

      # Delegate model_name to the underlying provider.
      #
      # @return [String]
      def model_name
        @provider.model_name
      end

      # Delegate the per-provider input cap so Builder's chunker / text
      # preparer wiring keeps working when the cache wrapper is in front
      # of the provider. Without this, `respond_to?(:max_input_tokens)`
      # returns true (inherited from Interface) but the call raises
      # NotImplementedError.
      #
      # @return [Integer, nil]
      def max_input_tokens
        return @provider.max_input_tokens if @provider.respond_to?(:max_input_tokens)

        nil
      end

      private

      # Split texts into cached hits and uncached misses.
      #
      # @param texts [Array<String>]
      # @return [Array(Array, Array<String>, Array<Integer>)]
      def partition_cached(texts)
        results = Array.new(texts.size)
        misses = []
        miss_indices = []

        texts.each_with_index do |text, idx|
          cached = @cache_store.read(embedding_key(text))
          if cached
            results[idx] = cached
          else
            misses << text
            miss_indices << idx
          end
        end

        [results, misses, miss_indices]
      end

      # Build a cache key for an embedding text.
      #
      # @param text [String]
      # @return [String]
      def embedding_key(text)
        Cache.cache_key(:embeddings, Digest::SHA256.hexdigest(text))
      end
    end

    # Decorator that wraps a {Retriever} with result caching.
    #
    # Caches the full formatted context output (the most token-expensive artifact)
    # keyed by query + budget. Also caches the structural context overview
    # separately with a longer TTL.
    #
    # @example
    #   retriever = Woods::Retriever.new(...)
    #   cached = CachedRetriever.new(retriever: retriever, cache_store: store)
    #   cached.retrieve("How does User work?")  # full pipeline + cache
    #   cached.retrieve("How does User work?")  # instant cache hit
    #
    class CachedRetriever
      # @param retriever [Retriever] The real retriever instance
      # @param cache_store [CacheStore] Cache backend instance
      # @param context_ttl [Integer] TTL for formatted context results
      def initialize(retriever:, cache_store:, context_ttl: DEFAULT_TTLS[:context])
        @retriever = retriever
        @cache_store = cache_store
        @context_ttl = context_ttl
      end

      # Expose the wrapped stores so the MCP +reload+ tool and
      # {Woods::MCP::Bootstrapper.reload_stores!} can re-hydrate caches in
      # place regardless of whether caching is enabled. Without these
      # delegations, reload is a silent no-op when +cache_enabled+ is true —
      # the bootstrapper would see +nil+ stores on the wrapper and skip.
      def vector_store   = @retriever.vector_store
      def metadata_store = @retriever.metadata_store
      def graph_store    = @retriever.graph_store

      # Invalidate every cached context result. Called from the MCP +reload+
      # tool after the retriever's stores have been re-hydrated from a fresh
      # embed — otherwise cached results from the old embedding run would
      # linger until their TTL expires and contradict the new stores.
      #
      # Embedding caches (query → vector) are NOT cleared: the query-vector
      # mapping is deterministic for a given provider+model and survives any
      # index reload. Only context results (query → ranked units) go stale.
      #
      # @return [void]
      def invalidate_context_cache!
        @cache_store.clear(namespace: :context)
      rescue StandardError => e
        warn("[Woods] CachedRetriever context-cache invalidation failed: #{e.message}")
      end

      # Execute the retrieval pipeline with context-level caching.
      #
      # On cache hit, returns a RetrievalResult reconstructed from cached data
      # without running any pipeline stages. On miss, delegates to the real
      # retriever and caches the serializable parts of the result.
      #
      # Cache key includes +types:+ / +exclude_types:+ so a run with a
      # narrower type filter doesn't return a broader-filter cached result.
      #
      # @param query [String] Natural language query
      # @param budget [Integer] Token budget
      # @param types [Array<String, Symbol>, nil] Include-only filter
      # @param exclude_types [Array<String, Symbol>, nil] Additional exclusions
      # @return [Retriever::RetrievalResult]
      def retrieve(query, budget: 8000, types: nil, exclude_types: nil)
        key = context_key(query, budget, types: types, exclude_types: exclude_types)
        cached = @cache_store.read(key)

        if cached
          return Retriever::RetrievalResult.new(
            context: cached['context'],
            sources: cached['sources'],
            classification: nil,
            strategy: cached['strategy']&.to_sym,
            tokens_used: cached['tokens_used'],
            budget: budget,
            trace: nil
          )
        end

        result = @retriever.retrieve(query, budget: budget, types: types, exclude_types: exclude_types)

        begin
          @cache_store.write(key, serialize_result(result), ttl: @context_ttl)
        rescue StandardError => e
          warn("[Woods] CachedRetriever cache write failed: #{e.message}")
        end

        result
      end

      private

      # Build a cache key for a context result.
      #
      # Includes the type filter kwargs so distinct filter combinations miss
      # each other — a lookup with +types: ["service"]+ must not return a
      # previously-cached broad result.
      #
      # @param query [String]
      # @param budget [Integer]
      # @param types [Array<String, Symbol>, nil]
      # @param exclude_types [Array<String, Symbol>, nil]
      # @return [String]
      def context_key(query, budget, types: nil, exclude_types: nil)
        Cache.cache_key(:context, query, budget.to_s, fingerprint(types), fingerprint(exclude_types))
      end

      def fingerprint(types)
        return '' if types.nil? || types.empty?

        types.map(&:to_s).sort.join(',')
      end

      # Serialize a RetrievalResult to a JSON-safe hash.
      #
      # Only caches the fields needed to reconstruct a useful result:
      # context string, sources list, strategy, and token count.
      #
      # @param result [Retriever::RetrievalResult]
      # @return [Hash]
      def serialize_result(result)
        {
          'context' => result.context,
          'sources' => result.sources,
          'strategy' => result.strategy&.to_s,
          'tokens_used' => result.tokens_used
        }
      end
    end
  end
end
