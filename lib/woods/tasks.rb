# frozen_string_literal: true

require_relative 'builder'
require_relative 'embedding/indexer'
require_relative 'embedding/text_preparer'
require_relative 'resolved_config'

module Woods
  # Small helpers invoked from `lib/tasks/woods.rake`.
  #
  # Keeps rake task bodies to a couple of lines each so the real work lives in
  # plain Ruby that can be unit-tested without Rake's global state.
  module Tasks
    module_function

    # Build an {Embedding::Indexer} wired to the provider and stores described
    # by {Woods.configuration}. Uses {Builder} so `config.embedding_provider`,
    # `config.embedding_options`, and `config.vector_store(_options)` are all
    # honoured — prior to this the rake tasks hardcoded Ollama + InMemory and
    # silently ignored configuration, which was invisible until the provider
    # tried to reach an unreachable default host.
    #
    # The TextPreparer and SemanticChunker are tuned to the selected
    # provider so oversize units are split into chunks that fit the
    # provider's input budget (e.g. Ollama's num_ctx, OpenAI's 8k cap).
    #
    # @return [Embedding::Indexer]
    def build_embed_indexer
      config = Woods.configuration
      builder = Builder.new(config)
      provider = builder.build_embedding_provider

      # The Indexer gets the provider wrapped in the resilience stack
      # (retry with backoff + per-instance circuit breaker) so a transient
      # 429/5xx degrades the run instead of aborting it — on the :local /
      # :shared_filesystem presets the dump only lands at end-of-run, so an
      # unwrapped mid-run rate limit used to discard every embedding
      # already paid for (#188 / B-076). The *raw* provider still feeds
      # the tokenizer-calibration helpers and the ResolvedConfig probe,
      # which key off the provider's concrete class.
      resilient_provider = builder.build_resilient_embedding_provider(provider)

      # Wire the persistence-arc pieces (resolved_config, metadata_store,
      # dump_retention_count) so Indexer#persist_snapshot can write
      # woods.json, dump metadata, and honour the user's retention setting.
      # Without these kwargs, embed writes vectors.bin + latest pointer but
      # never writes woods.json — which breaks the standalone woods-mcp
      # Shape-2 boot path entirely.
      #
      # metadata_store and resolved_config are nil-safe — hosts that don't
      # configure metadata or that pre-date the persistence arc still work.
      vector_store = builder.build_vector_store(dimensions: provider.dimensions)
      verify_store_dimensions!(vector_store, provider)

      Embedding::Indexer.new(
        provider: resilient_provider,
        text_preparer: builder.build_text_preparer(provider),
        vector_store: vector_store,
        metadata_store: config.metadata_store ? builder.build_metadata_store : nil,
        resolved_config: build_resolved_config(config, provider: provider),
        chunker: builder.build_chunker(provider),
        dump_retention_count: config.dump_retention_count,
        output_dir: ENV.fetch('WOODS_OUTPUT', config.output_dir)
      )
    end

    # Refuse to embed into a store built for a different vector width (#214).
    #
    # Durable stores are created once and reused: pgvector's `ensure_schema!`
    # is `CREATE TABLE IF NOT EXISTS` and Qdrant treats its collection PUT as
    # idempotent, so changing `embedding_model` leaves the old width in place.
    # Without this check the run embedded everything first and only then hit a
    # per-row server error — `PG::DataException: expected 384 dimensions, not
    # 768`, or a Qdrant 400 — naming no remedy.
    #
    # The dump path has had this check since the persistence arc
    # ({Storage::Snapshotter::Vector} validates the WVF1 header against
    # `resolved_config.dimension`); this extends the same guarantee to the
    # durable backends, which had none. It is a *pre-flight* check: adapters
    # that cannot report a width, and stores that do not exist yet, return nil
    # and are simply not checked.
    #
    # @param vector_store [Object] the configured store
    # @param provider [#dimensions] the raw (unwrapped) embedding provider
    # @raise [Woods::MCP::DimensionMismatch] when the widths disagree
    # @return [void]
    def verify_store_dimensions!(vector_store, provider)
      return unless vector_store.respond_to?(:stored_dimensions)
      return unless provider.respond_to?(:dimensions)

      stored = vector_store.stored_dimensions
      expected = provider.dimensions
      return if stored.nil? || expected.nil? || stored == expected

      require_relative 'mcp/errors'
      raise Woods::MCP::DimensionMismatch.new(
        "#{vector_store.class} holds #{stored}-dimension vectors but the configured provider " \
        "produces #{expected}. Embedding into it would fail per-row. Re-index from scratch: " \
        'drop the vector store (woods_vectors table / Qdrant collection), then run ' \
        'woods:extract && woods:embed.',
        details: { stored_dimension: stored, provider_dimension: expected, store: vector_store.class.to_s }
      )
    end

    # Build a ResolvedConfig snapshot from the live Woods::Configuration.
    # Returns nil if the configuration doesn't have enough to produce one
    # (pre-persistence-arc hosts) so the Indexer falls back to the legacy
    # dump-without-woods.json behaviour.
    #
    # Passes the live +provider+ so {ResolvedConfig.from_configuration} can
    # probe +provider.dimensions+ — without this, Ollama snapshots record
    # +dimension: 0+ and every subsequent MCP boot fails a spurious
    # dimension-mismatch check against the real stored vectors.
    def build_resolved_config(config, provider: nil)
      return nil unless config.embedding_provider

      ResolvedConfig.from_configuration(config, provider: provider)
    rescue StandardError
      nil
    end

    # Print an indexer stats hash in the format the rake tasks have historically
    # used. `mode:` only affects the header line.
    #
    # @param stats [Hash]
    # @param mode [Symbol] :full or :incremental
    def print_embed_stats(stats, mode:)
      header = mode == :incremental ? 'Incremental embedding complete!' : 'Embedding complete!'
      puts
      puts header
      puts "  Processed: #{stats[:processed]}"
      puts "  Skipped:   #{stats[:skipped]}"
      puts "  Errors:    #{stats[:errors]}"
    end
  end
end
