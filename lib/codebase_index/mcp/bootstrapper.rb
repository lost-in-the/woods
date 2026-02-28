# frozen_string_literal: true

module CodebaseIndex
  module MCP
    # Shared setup logic for MCP server executables.
    #
    # Validates the index directory, checks for a manifest, and builds
    # an optional retriever for semantic search — all duplicated between
    # the stdio and HTTP server entry points.
    #
    module Bootstrapper
      # Resolve and validate the index directory from CLI args or environment.
      #
      # @param argv [Array<String>] Command-line arguments
      # @return [String] Validated index directory path
      def self.resolve_index_dir(argv)
        dir = argv[0] || ENV['CODEBASE_INDEX_DIR'] || Dir.pwd

        unless Dir.exist?(dir)
          warn "Error: Index directory does not exist: #{dir}"
          exit 1
        end

        unless File.exist?(File.join(dir, 'manifest.json'))
          warn "Error: No manifest.json found in: #{dir}"
          warn 'Run `bundle exec rake codebase_index:extract` in your Rails app first.'
          exit 1
        end

        dir
      end

      # Attempt to build a retriever for semantic search.
      #
      # Auto-configures from environment variables when no explicit configuration
      # exists. Returns nil if embedding is unavailable or setup fails.
      #
      # @return [CodebaseIndex::Retriever, nil]
      def self.build_retriever
        config = CodebaseIndex.configuration

        openai_key = ENV.fetch('OPENAI_API_KEY', nil)
        if !config.embedding_provider && openai_key
          config.vector_store = :in_memory
          config.metadata_store = :in_memory
          config.graph_store = :in_memory
          config.embedding_provider = :openai
          config.embedding_options = { api_key: openai_key }
        end

        CodebaseIndex::Builder.new(config).build_retriever if config.embedding_provider
      rescue StandardError => e
        warn "Note: Semantic search unavailable (#{e.message}). Using pattern-based search only."
        nil
      end
    end
  end
end
