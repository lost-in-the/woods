# frozen_string_literal: true

require 'digest'
require_relative 'cache_store'

module Woods
  module Cache
    # Raised by {InflightEntry#await} when the owning thread aborted before
    # either fulfilling or rejecting the entry — for example on `Interrupt`,
    # `Thread#kill`, or a non-StandardError exception that bypasses the explicit
    # `rescue`. Waiters receive this instead of blocking forever.
    #
    # @api private
    class OwnerAbortedError < StandardError
      def initialize(msg = 'embedding fetch owner aborted before fulfill')
        super
      end
    end

    # Per-text in-flight entry used for single-flight coordination in
    # {CachedEmbeddingProvider#embed_batch}. When thread A is already fetching an
    # embedding for text T, thread B's miss for T attaches to A's entry and waits
    # on its condition variable rather than issuing a parallel provider call.
    # See issue #88.
    #
    # @api private
    class InflightEntry
      def initialize
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @done = false
        @value = nil
        @error = nil
        @waiter_count = 0
      end

      # Publish the computed value and wake every waiter. Idempotent — a second
      # call (e.g. from an `ensure` that rejects unfulfilled entries) is a no-op
      # so the hardening in {CachedEmbeddingProvider#fetch_and_fulfill} is safe.
      def fulfill(value)
        @mutex.synchronize do
          return if @done

          @value = value
          @done = true
          @cond.broadcast
        end
      end

      # Publish an exception so waiters fail fast instead of blocking forever.
      # Idempotent — see {#fulfill}.
      def reject(error)
        @mutex.synchronize do
          return if @done

          @error = error
          @done = true
          @cond.broadcast
        end
      end

      # Block until {#fulfill} or {#reject} is called, then return the value
      # (or re-raise the error) to the waiting thread. `@waiter_count` is bumped
      # under the mutex so tests can deterministically wait for "N threads have
      # attached to this entry" instead of polling coarse Thread#status values.
      def await
        @mutex.synchronize do
          @waiter_count += 1
          begin
            @cond.wait(@mutex) until @done
          ensure
            @waiter_count -= 1
          end
        end
        raise @error if @error

        @value
      end

      # Number of threads currently blocked in {#await}. Thread-safe observation
      # used primarily by concurrent specs to synchronize without relying on
      # `Thread#status` (which can transiently report 'sleep' on unrelated
      # mutex contention — see issue #94 CI flake on MRI 3.1/3.2).
      #
      # @return [Integer]
      def waiter_count
        @mutex.synchronize { @waiter_count }
      end
    end

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
        @inflight = {}
        @inflight_mutex = Mutex.new
      end

      # Embed a single text, returning a cached vector when available.
      #
      # Shares the per-text single-flight map with {#embed_batch}, so concurrent
      # `embed("x")` / `embed_batch(["x", ...])` misses for the same text all
      # attach to the same in-flight entry and produce exactly one provider call.
      #
      # @param text [String] Text to embed
      # @return [Array<Float>] Embedding vector
      def embed(text)
        cached = @cache_store.read(embedding_key(text))
        return cached unless cached.nil?

        with_single_flight(text) { @provider.embed(text) }
      end

      # Embed a batch of texts, using cached vectors for any previously seen texts.
      #
      # Only texts that are not already cached are sent to the real provider.
      # Results are merged back in original order.
      #
      # Uses per-text single-flight to prevent cache-miss stampedes: when N threads
      # concurrently miss on the same text, exactly one calls the provider while
      # the others attach to its {InflightEntry} and wait. See issue #88.
      #
      # @param texts [Array<String>] Texts to embed
      # @return [Array<Array<Float>>] Embedding vectors (same order as input)
      def embed_batch(texts)
        results, misses, miss_indices = partition_cached(texts)
        return results if misses.empty?

        to_fetch, to_fetch_positions, our_entries, awaiting = claim_inflight(misses)

        fetch_and_fulfill(to_fetch, to_fetch_positions, our_entries, results, miss_indices)
        await_others(awaiting, results, miss_indices)

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

      # Run a provider block for a single text under the shared single-flight map.
      # The first thread to miss on `text` becomes the owner, runs the block, caches
      # the result, and fulfills the entry. Concurrent callers for the same text
      # wait on the same entry. Errors propagate to waiters via {InflightEntry#reject}.
      #
      # @param text [String]
      # @yieldreturn [Array<Float>] the freshly computed embedding vector
      # @return [Array<Float>]
      def with_single_flight(text)
        entry, owner = claim_single(text)
        return entry.await unless owner

        begin
          vector = yield
          write_cache(text, vector)
          entry.fulfill(vector)
          vector
        rescue StandardError => e
          entry.reject(e)
          raise
        ensure
          entry.reject(OwnerAbortedError.new)
          clear_inflight([text])
        end
      end

      # Single-text counterpart of {#claim_inflight}. Returns the entry for `text`
      # and a boolean indicating whether the current thread is the owner.
      #
      # @param text [String]
      # @return [Array(InflightEntry, Boolean)]
      def claim_single(text)
        @inflight_mutex.synchronize do
          existing = @inflight[text]
          return [existing, false] if existing

          entry = InflightEntry.new
          @inflight[text] = entry
          [entry, true]
        end
      end

      # Claim ownership of miss texts that no other thread is currently fetching.
      # Returns four arrays describing the split of `misses`:
      #
      # - `to_fetch` — texts this thread owns and will hand to the provider
      # - `to_fetch_positions` — each owned text's index into `misses`
      # - `our_entries` — {InflightEntry} instances this thread will fulfill/reject
      # - `awaiting` — `[position, entry]` pairs for texts already being fetched
      #   by another thread; this thread will block on `entry.await` instead of
      #   calling the provider
      #
      # The inflight map is only held during this bookkeeping — not during the
      # provider call or the subsequent waits.
      #
      # @param misses [Array<String>]
      # @return [Array(Array<String>, Array<Integer>, Array<InflightEntry>, Array<Array>)]
      def claim_inflight(misses)
        to_fetch = []
        to_fetch_positions = []
        our_entries = []
        awaiting = []

        @inflight_mutex.synchronize do
          misses.each_with_index do |text, pos|
            existing = @inflight[text]
            if existing
              awaiting << [pos, existing]
            else
              entry = InflightEntry.new
              @inflight[text] = entry
              our_entries << entry
              to_fetch << text
              to_fetch_positions << pos
            end
          end
        end

        [to_fetch, to_fetch_positions, our_entries, awaiting]
      end

      # Call the provider for owned texts, write each vector to the cache, and
      # fulfill the owned entries so waiters wake with the fresh vector.
      #
      # The `ensure` block guarantees every owned entry reaches a terminal state
      # and leaves the inflight map, even under paths the `rescue` misses —
      # non-StandardError exceptions, `Thread#kill`, or a future refactor that
      # introduces a raise into the fulfill loop. {InflightEntry#fulfill} /
      # {InflightEntry#reject} are idempotent, so the fallback reject on
      # already-fulfilled entries is a no-op.
      #
      # @return [void]
      def fetch_and_fulfill(to_fetch, to_fetch_positions, our_entries, results, miss_indices)
        return if to_fetch.empty?

        begin
          fresh_vectors = @provider.embed_batch(to_fetch)
          # Reject a malformed provider response up-front rather than silently
          # fulfilling waiters with `nil` (or masking a missing tail vector by
          # under-writing the cache).
          if fresh_vectors.size != to_fetch.size
            raise ArgumentError,
                  "provider returned #{fresh_vectors.size} vectors for #{to_fetch.size} texts"
          end
        rescue StandardError => e
          our_entries.each { |entry| entry.reject(e) }
          raise
        end

        to_fetch.each_with_index do |text, i|
          vector = fresh_vectors[i]
          results[miss_indices[to_fetch_positions[i]]] = vector
          write_cache(text, vector)
          our_entries[i].fulfill(vector)
        end
      ensure
        our_entries.each { |entry| entry.reject(OwnerAbortedError.new) }
        clear_inflight(to_fetch)
      end

      # Block on entries owned by other threads, then slot their fulfilled vectors
      # into `results`. Any exception from a sibling thread's provider call is
      # re-raised here via {InflightEntry#await}.
      #
      # @param awaiting [Array<Array>] pairs of `[position_in_misses, InflightEntry]`
      # @param results [Array]
      # @param miss_indices [Array<Integer>]
      # @return [void]
      def await_others(awaiting, results, miss_indices)
        awaiting.each do |pos, entry|
          results[miss_indices[pos]] = entry.await
        end
      end

      # Remove the given texts from the inflight map.
      #
      # @param texts [Array<String>]
      # @return [void]
      def clear_inflight(texts)
        @inflight_mutex.synchronize { texts.each { |t| @inflight.delete(t) } }
      end

      # Write one vector to the cache, warning on backend failure rather than
      # propagating — a transient cache write error must not fail the embed call.
      #
      # @param text [String]
      # @param vector [Array<Float>]
      # @return [void]
      def write_cache(text, vector)
        @cache_store.write(embedding_key(text), vector, ttl: @ttl)
      rescue StandardError => e
        warn("[Woods] CachedEmbeddingProvider cache write failed: #{e.message}")
      end

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
        return rehydrate_cached(cached, budget) if cached

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
      def rehydrate_cached(cached, budget)
        Retriever::RetrievalResult.new(
          context: cached['context'],
          sources: cached['sources'],
          classification: nil,
          strategy: cached['strategy']&.to_sym,
          tokens_used: cached['tokens_used'],
          budget: budget,
          trace: nil,
          type_rank_context: rehydrate_type_rank_context(cached['type_rank_context'])
        )
      end

      def serialize_result(result)
        {
          'context' => result.context,
          'sources' => result.sources,
          'strategy' => result.strategy&.to_s,
          'tokens_used' => result.tokens_used,
          'type_rank_context' => serialize_type_rank_context(result.type_rank_context)
        }
      end

      # type_rank_context is a Hash<String => Hash<Symbol, ...>> with
      # :source carrying a Symbol value. JSON-backed caches (Redis,
      # SolidCache) collapse both to strings on the round-trip, so we
      # serialize explicitly and re-symbolize both the inner keys and
      # the :source value on rehydrate. The programmatic contract is
      # "symbol keys, symbol :source value" regardless of cache hit
      # vs miss.
      def serialize_type_rank_context(ctx)
        return nil if ctx.nil?

        ctx.each_with_object({}) do |(type, info), out|
          out[type] = info.each_with_object({}) do |(k, v), h|
            h[k.to_s] = k == :source ? v.to_s : v
          end
        end
      end

      def rehydrate_type_rank_context(raw)
        return nil if raw.nil?

        raw.each_with_object({}) do |(type, info), out|
          out[type] = info.each_with_object({}) do |(k, v), h|
            sym_k = k.to_sym
            h[sym_k] = sym_k == :source ? v.to_sym : v
          end
        end
      end
    end
  end
end
