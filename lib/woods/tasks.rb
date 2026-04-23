# frozen_string_literal: true

require_relative 'builder'
require_relative 'embedding/indexer'
require_relative 'embedding/text_preparer'

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

      Embedding::Indexer.new(
        provider: provider,
        text_preparer: builder.build_text_preparer(provider),
        vector_store: builder.build_vector_store,
        chunker: builder.build_chunker(provider),
        output_dir: ENV.fetch('WOODS_OUTPUT', config.output_dir)
      )
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
