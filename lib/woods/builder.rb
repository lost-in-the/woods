# frozen_string_literal: true

require_relative 'retriever'
require_relative 'storage/vector_store'
require_relative 'storage/pgvector'
require_relative 'storage/qdrant'
require_relative 'storage/metadata_store'
require_relative 'storage/graph_store'
require_relative 'embedding/provider'
require_relative 'embedding/openai'
require_relative 'embedding/fake'
require_relative 'resilience/retryable_provider'
require_relative 'embedding/text_preparer'
require_relative 'embedding/token_counter'
require_relative 'token_utils'
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
    # :local              — fully local, no external services required (requires sqlite3 gem)
    # :shared_filesystem  — Shape 2: rake embed → separate MCP server reads from disk.
    #                       All stores in-memory + persisted to output_dir via the
    #                       Snapshotter. No sqlite3 gem needed. Requires output_dir set
    #                       AND readable by both the embed process and the MCP server.
    # :postgresql         — pgvector for vectors, OpenAI for embeddings
    # :production         — Qdrant for vectors, OpenAI for embeddings
    PRESETS = {
      local: {
        vector_store: :in_memory,
        metadata_store: :sqlite,
        graph_store: :in_memory,
        embedding_provider: :ollama
      },
      shared_filesystem: {
        vector_store: :in_memory,
        metadata_store: :in_memory,
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
    # @param name [Symbol] Preset name — one of :local, :shared_filesystem,
    #   :postgresql, or :production
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
    # Callers that need stores pre-populated from a dump (the Shape-2
    # MCP-serve path) can inject them via +vector_store:+ / +metadata_store:+.
    # Without these, fresh empty stores are constructed from config. This
    # is how the Bootstrapper hydrates from `Snapshotter.load_or_empty`
    # without Builder needing to know the Snapshotter exists.
    #
    # @param vector_store [Storage::VectorStore::Interface, nil]
    # @param metadata_store [Storage::MetadataStore::Interface, nil]
    # @param graph_store [Storage::GraphStore::Interface, nil] Pre-populated
    #   graph store. Without this, the retriever gets a fresh empty graph,
    #   which silently degrades +:hybrid+ retrieval (graph expansion returns
    #   no candidates). The Bootstrapper hydrates from +dependency_graph.json+
    #   on disk and passes the populated store here.
    # @return [Retriever, Cache::CachedRetriever] A fully wired retriever
    def build_retriever(vector_store: nil, metadata_store: nil, graph_store: nil)
      provider = build_resilient_embedding_provider
      cache = build_cache_store

      provider = wrap_with_embedding_cache(provider, cache) if cache

      retriever = Retriever.new(
        vector_store: vector_store || build_vector_store(dimensions: vector_dimensions(provider)),
        metadata_store: metadata_store || build_metadata_store,
        graph_store: graph_store || build_graph_store,
        embedding_provider: provider
      )

      cache ? wrap_with_retriever_cache(retriever, cache) : retriever
    end

    # Instantiate the vector store adapter specified by the configuration.
    #
    # The :pgvector branch also ensures the adapter's own schema exists —
    # see {#build_pgvector_store}.
    #
    # @return [Storage::VectorStore::Interface] Vector store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    # @raise [Woods::Error] if the pgvector schema cannot be created
    def build_vector_store(dimensions: nil)
      case @config.vector_store
      when :in_memory then Storage::VectorStore::InMemory.new
      when :pgvector then build_pgvector_store(dimensions)
      when :qdrant then build_qdrant_store(dimensions)
      else raise ArgumentError, "Unknown vector_store: #{@config.vector_store}"
      end
    end

    def vector_dimensions(provider)
      provider.dimensions if %i[pgvector qdrant].include?(@config.vector_store)
    end
    private :vector_dimensions

    # Instantiate the embedding provider specified by the configuration.
    #
    # `embedding_provider` accepts three shapes (#178):
    # - +:openai+ / +:ollama+ — the network-backed adapters.
    # - +:fake+ — {Embedding::Provider::Fake}: deterministic, offline, for
    #   CI/smoke runs. See {#build_fake_provider} for dimension resolution.
    # - an already-constructed provider *object* — anything responding to
    #   +#embed+ and +#embed_batch+ is returned as-is, so hosts can plug in
    #   their own implementation without patching the Builder. It flows
    #   through {#build_resilient_embedding_provider} like the built-ins.
    #
    # Strips `embedding_options` keys that belong to the ResolvedConfig layer
    # (like `:dimension`) before splatting into the provider's constructor —
    # those keys are useful for the Snapshotter's schema header but
    # aren't part of the provider's API.
    #
    # @return [Embedding::Provider::Interface] Embedding provider instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_embedding_provider
      configured = @config.embedding_provider
      return configured if provider_object?(configured)

      opts = provider_kwargs(configured)
      case configured
      when :openai then Embedding::Provider::OpenAI.new(**opts)
      when :ollama then Embedding::Provider::Ollama.new(**opts)
      when :fake then build_fake_provider(opts)
      else
        raise ArgumentError,
              "Unknown embedding_provider: #{configured}. Valid: :openai, :ollama, :fake, " \
              'or a provider object responding to #embed and #embed_batch'
      end
    end

    # Wrap an embedding provider in the resilience stack: retry with
    # full-jitter exponential backoff (Retry-After aware) plus a dedicated
    # {Resilience::CircuitBreaker}.
    #
    # This is the provider every pipeline entry point must hand to the
    # Indexer or Retriever — with it, a transient 429/5xx burst degrades a
    # run instead of aborting it (#188 / B-076). {#build_embedding_provider}
    # deliberately keeps returning the *raw* provider: the MCP boot path
    # ({MCP::ProviderProbe}) dispatches on the provider's concrete class and
    # reads its internals, so the wrap happens here, one layer up.
    #
    # Each call constructs a fresh breaker — breaker state is per-instance
    # and must never be shared across unrelated components.
    #
    # The wrap is harmless for providers that never raise transient
    # failures ({Embedding::Provider::Fake}, most injected provider
    # objects): nothing retryable ever fires, so the wrapper is a
    # transparent pass-through.
    #
    # @param provider [Embedding::Provider::Interface] raw provider to wrap;
    #   defaults to a freshly built one from the configuration
    # @return [Resilience::RetryableProvider] the wrapped provider
    def build_resilient_embedding_provider(provider = build_embedding_provider)
      Resilience::RetryableProvider.new(
        provider: provider,
        circuit_breaker: Resilience::CircuitBreaker.new
      )
    end

    PROVIDER_OPTION_KEYS = {
      openai: %i[api_key model dimension dimensions],
      ollama: %i[model host num_ctx read_timeout dimension dimensions],
      fake: %i[model dims dimension dimensions]
    }.freeze
    private_constant :PROVIDER_OPTION_KEYS

    def provider_kwargs(configured)
      opts = (@config.embedding_options || {}).transform_keys(&:to_sym)
      validate_provider_options!(configured, opts)
      apply_embedding_model!(opts)
      normalize_dimension_option!(configured, opts)
      validate_required_provider_options!(configured, opts)
      opts
    end
    private :provider_kwargs

    def validate_provider_options!(configured, opts)
      allowed = PROVIDER_OPTION_KEYS[configured]
      return unless allowed

      unknown = opts.keys - allowed
      return if unknown.empty?

      provider_name = configured.to_s.capitalize
      noun = unknown.one? ? 'option' : 'options'
      raise ConfigurationError,
            "Unknown #{provider_name} embedding #{noun}: #{unknown.join(', ')}. " \
            "Valid options: #{allowed.join(', ')}"
    end
    private :validate_provider_options!

    def validate_required_provider_options!(configured, opts)
      return unless configured == :openai
      return unless opts[:api_key].nil? || opts[:api_key].to_s.empty?

      raise ConfigurationError,
            'OpenAI requires embedding_options[:api_key]. Set it explicitly, typically from OPENAI_API_KEY.'
    end
    private :validate_required_provider_options!

    def apply_embedding_model!(opts)
      return if opts.key?(:model)
      return unless @config.respond_to?(:embedding_model_explicit?) && @config.embedding_model_explicit?

      opts[:model] = @config.embedding_model
    end
    private :apply_embedding_model!

    def normalize_dimension_option!(configured, opts)
      legacy_dimension = opts.delete(:dimension)
      dimensions = opts.delete(:dimensions)
      if conflicting_dimensions?(legacy_dimension, dimensions)
        raise ConfigurationError, 'embedding_options dimension and dimensions must match when both are provided'
      end

      dimension = dimensions || legacy_dimension
      return unless dimension

      opts[configured == :fake ? :dims : :dimensions] ||= dimension
    end
    private :normalize_dimension_option!

    def conflicting_dimensions?(legacy_dimension, dimensions)
      !legacy_dimension.nil? && !dimensions.nil? && legacy_dimension != dimensions
    end
    private :conflicting_dimensions?

    # True when the configured `embedding_provider` is not a Symbol naming a
    # built-in adapter but an already-constructed provider object (#178).
    # Duck-typed on the two methods every pipeline consumer calls; the rest
    # of {Embedding::Provider::Interface} (+#dimensions+, +#model_name+,
    # +#max_input_tokens+) is probed with +respond_to?+ at each call site,
    # so an object that omits them still works where they are optional.
    #
    # @param candidate [Object]
    # @return [Boolean]
    def provider_object?(candidate)
      !candidate.is_a?(Symbol) && candidate.respond_to?(:embed) && candidate.respond_to?(:embed_batch)
    end
    private :provider_object?

    # Build the deterministic fake provider (#178).
    #
    # Dimension resolution: `embedding_options[:dims]` maps directly onto
    # the {Embedding::Provider::Fake} constructor; failing that, the
    # ResolvedConfig-level `embedding_options[:dimension]` key — normally
    # snapshot-only bookkeeping stripped by {#provider_kwargs} — is
    # honoured, so hosts that declare their dimension there (and the MCP
    # boot path, which restores exactly that key from woods.json) get
    # vectors of the recorded dimension.
    #
    # @return [Embedding::Provider::Fake]
    def build_fake_provider(opts)
      Embedding::Provider::Fake.new(**opts)
    end
    private :build_fake_provider

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
      budget = safe_max_input_tokens(provider)
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
    # that still exceeds `num_ctx`. See docs/EMBEDDING_MODELS.md.
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
      budget = safe_max_input_tokens(provider)
      max_chars = ((budget * chars_per_token_for(provider)).floor - CHUNKER_PREFIX_ALLOWANCE if budget)

      # Guard against a budget so small that the prefix allowance leaves
      # no room for content. Without this, SemanticChunker#slice_by_lines
      # passes a negative repeat count to String#scan, which returns []
      # — every chunk becomes empty and is silently dropped, producing
      # zero embeddings with no error. Surface the misconfiguration loudly.
      raise ArgumentError, chunker_budget_message(provider, budget) if max_chars && max_chars <= 0

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
      return unless unwrap_provider(provider).is_a?(Embedding::Provider::Ollama)

      Embedding::TokenCounter.new
    end

    # Tokenizer-calibrated chars/token ratio for the given provider.
    # Delegates to {Woods::TokenUtils.chars_per_token_for} — the single
    # source of truth — after reducing the provider instance to a symbol.
    #
    # @param provider [Embedding::Provider::Interface]
    # @return [Float]
    def chars_per_token_for(provider)
      symbol = case unwrap_provider(provider)
               when Embedding::Provider::Ollama then :ollama
               else :openai
               end
      TokenUtils.chars_per_token_for(symbol)
    end

    # Provider input-token budget, or nil when the provider has none.
    # `respond_to?` alone is the wrong guard here: {Embedding::Provider::Interface}
    # *defines* +max_input_tokens+ as a +NotImplementedError+ stub, so a
    # provider that merely includes the interface without overriding it
    # still answers +respond_to?+ with +true+ (B-108) and raises when
    # called. A provider with no such method at all still needs the
    # +respond_to?+ guard to avoid a bare +NoMethodError+.
    #
    # @param provider [Embedding::Provider::Interface]
    # @return [Integer, nil]
    def safe_max_input_tokens(provider)
      return nil unless provider.respond_to?(:max_input_tokens)

      provider.max_input_tokens
    rescue NotImplementedError
      nil
    end

    # Reach the concrete provider through the resilience wrapper.
    # Tokenizer calibration dispatches on the provider's real class, so a
    # {Resilience::RetryableProvider} handed to {#build_text_preparer} or
    # {#build_chunker} must calibrate exactly like its inner provider —
    # without this, a wrapped Ollama silently got OpenAI ratios.
    #
    # @param provider [Embedding::Provider::Interface]
    # @return [Embedding::Provider::Interface] the innermost provider
    def unwrap_provider(provider)
      provider.is_a?(Resilience::RetryableProvider) ? provider.provider : provider
    end

    # Diagnostic for the build_chunker budget guard.
    #
    # @param provider [Embedding::Provider::Interface]
    # @param budget [Integer]
    # @return [String]
    def chunker_budget_message(provider, budget)
      "embedding model '#{provider.respond_to?(:model_name) ? provider.model_name : provider.class}' " \
        "reports a max_input_tokens of #{budget}, which leaves no room for " \
        "the chunk prefix (#{CHUNKER_PREFIX_ALLOWANCE} chars). Configure a " \
        'model with a larger native context, or set num_ctx explicitly.'
    end

    public

    # Instantiate the metadata store adapter specified by the configuration.
    #
    # @return [Storage::MetadataStore::Interface] Metadata store adapter instance
    # @raise [ArgumentError] if the configured type is not recognized
    def build_metadata_store
      case @config.metadata_store
      when :in_memory then Storage::MetadataStore::InMemory.new
      when :sqlite then Storage::MetadataStore::SQLite.new(**sqlite_metadata_options)
      else raise ArgumentError, "Unknown metadata_store: #{@config.metadata_store}"
      end
    end

    def sqlite_metadata_options
      opts = (@config.metadata_store_options || {}).transform_keys(&:to_sym)
      opts[:database] ||= File.join(@config.output_dir.to_s, 'metadata.sqlite3')
      opts
    end
    private :sqlite_metadata_options

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

    private

    # Construct the pgvector adapter and ensure its schema exists.
    #
    # The adapter reads and writes its own `woods_vectors` table. The
    # `woods:pgvector` generator can create it via a migration, but nothing
    # guarantees that migration ran — so the builder calls the adapter's
    # idempotent {Storage::VectorStore::Pgvector#ensure_schema!}
    # (CREATE ... IF NOT EXISTS DDL) after construction. Without this, the
    # first embed against a bare database fails with PG::UndefinedTable
    # (#187 / B-075). Schema/connection failures are re-raised as
    # {Woods::Error} with the original error preserved as the cause.
    #
    # @return [Storage::VectorStore::Pgvector]
    # @raise [Woods::Error] when the schema cannot be created
    def build_pgvector_store(provider_dimensions)
      opts = (@config.vector_store_options || {}).transform_keys(&:to_sym)
      validate_required_store_options!(:pgvector, opts, :connection)
      opts[:dimensions] = resolve_pgvector_dimensions(provider_dimensions, opts[:dimensions])
      store = Storage::VectorStore::Pgvector.new(**opts)
      begin
        store.ensure_schema!
        verify_pgvector_dimensions!(store, opts[:dimensions])
      rescue ConfigurationError
        raise
      rescue StandardError => e
        raise Woods::Error,
              "pgvector schema setup failed (#{e.class}: #{e.message}). " \
              'Verify vector_store_options[:connection] is a live PostgreSQL ' \
              'connection and that the pgvector extension is available ' \
              '(`rails generate woods:pgvector && rails db:migrate` sets it up via migration).'
      end
      store
    end

    def verify_pgvector_dimensions!(store, expected)
      actual = store.stored_dimensions
      return if actual.nil? || actual == expected

      raise ConfigurationError,
            "Stored pgvector dimensions #{actual} do not match embedding provider dimensions #{expected}. " \
            'Use a compatible table or rebuild the index.'
    end

    def resolve_pgvector_dimensions(provider_dimensions, configured_dimensions)
      if provider_dimensions && configured_dimensions && provider_dimensions != configured_dimensions
        raise ConfigurationError,
              "pgvector dimensions #{configured_dimensions} do not match embedding provider dimensions " \
              "#{provider_dimensions}"
      end

      provider_dimensions || configured_dimensions || raise(
        ConfigurationError,
        'pgvector requires vector_store_options[:dimensions] when built without an embedding provider'
      )
    end

    def build_qdrant_store(provider_dimensions)
      opts = (@config.vector_store_options || {}).transform_keys(&:to_sym)
      validate_required_store_options!(:qdrant, opts, :url, :collection)
      dimensions = resolve_qdrant_dimensions(provider_dimensions, opts[:dimensions])
      opts[:dimensions] = dimensions
      store = Storage::VectorStore::Qdrant.new(**opts)
      store.ensure_collection!(dimensions: dimensions)
      store
    end

    def validate_required_store_options!(adapter, opts, *keys)
      missing = keys.select { |key| opts[key].nil? || opts[key].to_s.empty? }
      return if missing.empty?

      requirements = missing.map { |key| "vector_store_options[:#{key}]" }.join(' and ')
      raise ConfigurationError, "#{adapter} requires #{requirements}"
    end

    def resolve_qdrant_dimensions(provider_dimensions, configured_dimensions)
      if provider_dimensions && configured_dimensions && provider_dimensions != configured_dimensions
        raise ConfigurationError,
              "Qdrant dimensions #{configured_dimensions} do not match embedding provider dimensions " \
              "#{provider_dimensions}"
      end

      provider_dimensions || configured_dimensions || raise(
        ConfigurationError,
        'Qdrant requires vector_store_options[:dimensions] when built without an embedding provider'
      )
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
