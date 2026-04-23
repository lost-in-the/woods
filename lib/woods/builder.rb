# frozen_string_literal: true

require_relative 'retriever'
require_relative 'storage/vector_store'
require_relative 'storage/pgvector'
require_relative 'storage/qdrant'
require_relative 'storage/metadata_store'
require_relative 'storage/graph_store'
require_relative 'embedding/provider'
require_relative 'embedding/openai'
require_relative 'embedding/text_preparer'
require_relative 'embedding/token_counter'
require_relative 'chunking/semantic_chunker'

module Woods
  # Builder reads a {Configuration} and instantiates the appropriate adapters,
  # returning a fully wired {Retriever} ready for use.
  #
  # Named presets are provided for common deployment scenarios. All presets can
  # be further customized with a block passed to {Woods.configure_with_preset}.
  #
  # @example Using a preset
  #   Woods.configure_with_preset(:local)
  #   result = Woods.retrieve("How does the User model work?")
  #
  # @example Using a preset with block customization
  #   Woods.configure_with_preset(:production) do |config|
  #     config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }
  #     config.vector_store_options = { url: ENV['QDRANT_URL'], collection: 'myapp' }
  #   end
  #
  class Builder # rubocop:disable Metrics/ClassLength
    # Named presets mapping to default adapter types.
    #
    # :local      — fully local, no external services required
    # :postgresql — pgvector for vectors, OpenAI for embeddings
    # :production — Qdrant for vectors, OpenAI for embeddings
    PRESETS = {
      local: {
        vector_store: :in_memory,
        metadata_store: :sqlite,
        graph_store: :in_memory,
        embedding_provider: :ollama
      },
      postgresql: {
        vector_store: :pgvector,
        metadata_store: :sqlite,
        graph_store: :in_memory,
        embedding_provider: :openai
      },
      production: {
        vector_store: :qdrant,
        metadata_store: :sqlite,
        graph_store: :in_memory,
        embedding_provider: :openai
      }
    }.freeze

    # Build a {Configuration} populated with the named preset's adapter types.
    #
    # @param name [Symbol] Preset name — one of :local, :postgresql, or :production
    # @return [Configuration] A new Configuration with preset values applied
    # @raise [ArgumentError] if the preset name is not recognized
    def self.preset_config(name)
      preset = PRESETS.fetch(name) do
        raise ArgumentError, "Unknown preset: #{name}. Valid: #{PRESETS.keys.join(', ')}"
      end
      config = Configuration.new
      preset.each { |key, value| config.public_send(:"#{key}=", value) }
      config
    end

    # @param config [Configuration] Configuration to read adapter types from
    def initialize(config = Woods.configuration)
      @config = config
    end

    # Build a {Retriever} wired with adapters from the configuration.
    #
    # When `cache_enabled` is true, the embedding provider is wrapped with
    # {Cache::CachedEmbeddingProvider} and the retriever is wrapped with
    # {Cache::CachedRetriever} for transparent caching of expensive operations.
    #
    # @return [Retriever, Cache::CachedRetriever] A fully wired retriever
    def build_retriever
      provider = build_embedding_provider
      cache = build_cache_store

      provider = wrap_with_embedding_cache(provider, cache) if cache

      retriever = Retriever.new(
        vector_store: build_vector_store,
        metadata_store: build_metadata_store,
        graph_store: build_graph_store,
        embedding_provider: provider
      )

      cache ? wrap_with_retriever_cache(retriever, cache) : retriever
    end

    # Instantiate the vector store adapter specified by the configuration.
    #
    # @return [Storage::VectorStore::Interface] Vector store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_vector_store
      case @config.vector_store
      when :in_memory then Storage::VectorStore::InMemory.new
      when :pgvector then Storage::VectorStore::Pgvector.new(**(@config.vector_store_options || {}))
      when :qdrant then Storage::VectorStore::Qdrant.new(**(@config.vector_store_options || {}))
      else raise ArgumentError, "Unknown vector_store: #{@config.vector_store}"
      end
    end

    # Instantiate the embedding provider specified by the configuration.
    #
    # @return [Embedding::Provider::Interface] Embedding provider instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_embedding_provider
      case @config.embedding_provider
      when :openai then Embedding::Provider::OpenAI.new(**(@config.embedding_options || {}))
      when :ollama then Embedding::Provider::Ollama.new(**(@config.embedding_options || {}))
      else raise ArgumentError, "Unknown embedding_provider: #{@config.embedding_provider}"
      end
    end

    # Build a {Embedding::TextPreparer} calibrated to a given provider.
    #
    # OpenAI embedders use tiktoken (cl100k_base) — 4.0 chars/token is a
    # good conservative average. Ollama BERT/WordPiece tokenizers
    # (nomic-embed-text, bge-*) run much hotter on dense Ruby/Rails
    # source — long CamelCase constants, docstrings, callback DSLs, and
    # heavy symbol use all sit below 2.0 chars/token in practice.
    # Empirically, a 16 KB chunk of `ActionMailer::Base` still blows the
    # 8192-token budget at 2.0 chars/token, so we budget at 1.5 to stay
    # clear of tokenizer surprises even on the densest Rails internals.
    #
    # `max_tokens` tracks the provider's actual input budget when it
    # reports one, falling back to the TextPreparer default otherwise.
    #
    # @param provider [Embedding::Provider::Interface]
    # @return [Embedding::TextPreparer]
    def build_text_preparer(provider)
      chars_per_token = chars_per_token_for(provider)
      budget = provider.respond_to?(:max_input_tokens) ? provider.max_input_tokens : nil
      max_tokens = budget || Embedding::TextPreparer::DEFAULT_MAX_TOKENS

      Embedding::TextPreparer.new(max_tokens: max_tokens, chars_per_token: chars_per_token)
    end

    # Build a {Chunking::SemanticChunker} sized to a given provider.
    #
    # `max_chars` is derived from the provider's input budget and the
    # matching chars-per-token ratio, minus the context-prefix
    # allowance the Indexer accounts for separately. Units that exceed
    # this ceiling get sliced so no single chunk can blow the provider's
    # input cap.
    #
    # For Ollama (and other BERT/WordPiece-backed models), char-based
    # estimation is unreliable — CamelCase, `::` separators, and symbol
    # literals tokenize much denser than chars/token averages suggest.
    # When the optional `tokenizers` gem is installed, pass a
    # {Embedding::TokenCounter} and `max_tokens` so the chunker can
    # verify every slice with the real tokenizer and re-split any piece
    # that still exceeds `num_ctx`. See docs/EMBEDDING_CHUNK_SIZING.md.
    #
    # Ollama v0.13.5+ stopped honouring `truncate: true` on `/api/embed`
    # (ollama/ollama#14186), so any chunk that exceeds `num_ctx` returns
    # a 400 rather than being silently truncated. Exact client-side
    # sizing is the only reliable path until the regression is fixed
    # upstream.
    #
    # @param provider [Embedding::Provider::Interface]
    # @return [Chunking::SemanticChunker]
    def build_chunker(provider)
      budget = provider.respond_to?(:max_input_tokens) ? provider.max_input_tokens : nil
      max_chars = ((budget * chars_per_token_for(provider)).floor - CHUNKER_PREFIX_ALLOWANCE if budget)

      token_counter = token_counter_for(provider)
      max_tokens = token_counter && budget ? budget - PREFIX_TOKEN_ALLOWANCE : nil

      Chunking::SemanticChunker.new(
        max_chars: max_chars,
        token_counter: token_counter,
        max_tokens: max_tokens
      )
    end

    # Character allowance reserved for the TextPreparer context prefix
    # ([type] id / namespace / file / deps) — kept in sync with the
    # Indexer's own PREFIX_CHAR_ALLOWANCE constant.
    CHUNKER_PREFIX_ALLOWANCE = 512
    private_constant :CHUNKER_PREFIX_ALLOWANCE

    # Token-side sibling of {CHUNKER_PREFIX_ALLOWANCE}. Reserved for the
    # TextPreparer prefix when tokenizer-driven sizing is active — a bit
    # generous to cover long file paths and dep lists.
    PREFIX_TOKEN_ALLOWANCE = 256
    private_constant :PREFIX_TOKEN_ALLOWANCE

    private

    # Return a TokenCounter for providers that benefit from exact token
    # counting. OpenAI's tiktoken ratios are already stable at 4.0
    # chars/token on code, so it doesn't need this.
    #
    # @param provider [Embedding::Provider::Interface]
    # @return [Embedding::TokenCounter, nil]
    def token_counter_for(provider)
      return unless provider.is_a?(Embedding::Provider::Ollama)

      Embedding::TokenCounter.new
    end

    # Tokenizer-calibrated chars/token ratio for the given provider.
    #
    # @param provider [Embedding::Provider::Interface]
    # @return [Float]
    def chars_per_token_for(provider)
      case provider
      when Embedding::Provider::Ollama then 1.5
      else Embedding::TextPreparer::DEFAULT_CHARS_PER_TOKEN
      end
    end

    # Instantiate the metadata store adapter specified by the configuration.
    #
    # @return [Storage::MetadataStore::Interface] Metadata store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_metadata_store
      case @config.metadata_store
      when :in_memory then Storage::MetadataStore::InMemory.new
      when :sqlite then Storage::MetadataStore::SQLite.new(**(@config.metadata_store_options || {}))
      else raise ArgumentError, "Unknown metadata_store: #{@config.metadata_store}"
      end
    end

    # Instantiate the graph store adapter specified by the configuration.
    #
    # @return [Storage::GraphStore::Interface] Graph store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_graph_store
      case @config.graph_store
      when :in_memory then Storage::GraphStore::Memory.new
      else raise ArgumentError, "Unknown graph_store: #{@config.graph_store}"
      end
    end

    # Build a cache store from configuration, or nil if caching is disabled.
    #
    # @return [Cache::CacheStore, nil]
    def build_cache_store
      return nil unless @config.cache_enabled

      opts = @config.cache_options || {}

      case @config.cache_store
      when :memory
        Cache::InMemory.new(max_entries: opts.fetch(:max_entries, 500))
      when :redis
        require_relative 'cache/redis_cache_store'
        Cache::RedisCacheStore.new(redis: opts.fetch(:redis), default_ttl: opts[:default_ttl])
      when :solid_cache
        require_relative 'cache/solid_cache_store'
        Cache::SolidCacheStore.new(cache: opts.fetch(:cache), default_ttl: opts[:default_ttl])
      when Cache::CacheStore
        @config.cache_store
      else
        raise ArgumentError, "Unknown cache_store: #{@config.cache_store}"
      end
    end

    # Wrap an embedding provider with caching.
    #
    # @param provider [Embedding::Provider::Interface]
    # @param cache [Cache::CacheStore]
    # @return [Cache::CachedEmbeddingProvider]
    def wrap_with_embedding_cache(provider, cache)
      ttls = (@config.cache_options || {}).fetch(:ttl, {})
      Cache::CachedEmbeddingProvider.new(
        provider: provider,
        cache_store: cache,
        ttl: ttls.fetch(:embeddings, Cache::DEFAULT_TTLS[:embeddings])
      )
    end

    # Wrap a retriever with caching.
    #
    # @param retriever [Retriever]
    # @param cache [Cache::CacheStore]
    # @return [Cache::CachedRetriever]
    def wrap_with_retriever_cache(retriever, cache)
      ttls = (@config.cache_options || {}).fetch(:ttl, {})
      Cache::CachedRetriever.new(
        retriever: retriever,
        cache_store: cache,
        context_ttl: ttls.fetch(:context, Cache::DEFAULT_TTLS[:context])
      )
    end
  end
end
