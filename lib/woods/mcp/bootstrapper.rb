# frozen_string_literal: true

module Woods
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
        dir = argv[0] || ENV['WOODS_DIR'] || Dir.pwd

        unless Dir.exist?(dir)
          warn "Error: Index directory does not exist: #{dir}"
          exit 1
        end

        unless File.exist?(File.join(dir, 'manifest.json'))
          warn "Error: No manifest.json found in: #{dir}"
          warn 'Run `bundle exec rake woods:extract` in your Rails app first.'
          exit 1
        end

        dir
      end

      # Build a snapshot store for temporal tracking.
      #
      # Auto-enables when a SQLite database already exists in the index directory,
      # or when WOODS_SNAPSHOTS=true is set. The database is created and
      # migrated automatically. Falls back to JSON file store when SQLite is
      # unavailable or encounters errors.
      #
      # @param index_dir [String] Path to extraction output directory
      # @return [Woods::Temporal::SnapshotStore, Woods::Temporal::JsonSnapshotStore, nil]
      def self.build_snapshot_store(index_dir)
        db_path = File.join(index_dir, 'woods.sqlite3')
        enabled = ENV['WOODS_SNAPSHOTS'] == 'true' ||
                  Woods.configuration.enable_snapshots ||
                  File.exist?(db_path)

        return nil unless enabled

        begin
          require 'sqlite3'
          require_relative '../db/migrator'
          require_relative '../temporal/snapshot_store'

          db = SQLite3::Database.new(db_path)
          db.results_as_hash = true

          Woods::Db::Migrator.new(connection: db).migrate!
          Woods::Temporal::SnapshotStore.new(connection: db)
        rescue LoadError
          warn 'Note: sqlite3 gem not available, using JSON file-based snapshot store.'
          require_relative '../temporal/json_snapshot_store'
          Woods::Temporal::JsonSnapshotStore.new(dir: index_dir)
        rescue StandardError => e
          warn "Note: SQLite snapshot store failed (#{e.class}: #{e.message}), using JSON fallback."
          require_relative '../temporal/json_snapshot_store'
          Woods::Temporal::JsonSnapshotStore.new(dir: index_dir)
        end
      end

      # Attempt to build a retriever for semantic search.
      #
      # Auto-configures from environment variables when no explicit configuration
      # exists. Probes for OpenAI API key first, then checks for a reachable Ollama
      # instance. Emits a one-line STDERR banner indicating whether semantic search
      # is enabled and which provider is active.
      #
      # @return [Woods::Retriever, nil]
      def self.build_retriever
        config = Woods.configuration

        openai_key = ENV.fetch('OPENAI_API_KEY', nil)
        if !config.embedding_provider && openai_key
          config.vector_store = :in_memory
          config.metadata_store = :in_memory
          config.graph_store = :in_memory
          config.embedding_provider = :openai
          config.embedding_options = { api_key: openai_key }
        end

        if !config.embedding_provider && ollama_reachable?
          config.vector_store = :in_memory
          config.metadata_store = :in_memory
          config.graph_store = :in_memory
          config.embedding_provider = :ollama
          config.embedding_options = {
            host: ENV.fetch('OLLAMA_BASE_URL', 'http://localhost:11434'),
            model: ENV.fetch('OLLAMA_EMBED_MODEL', 'nomic-embed-text')
          }
        end

        if config.embedding_provider
          retriever = Woods::Builder.new(config).build_retriever
          warn "[woods-mcp] semantic search: enabled (#{config.embedding_provider})"
          retriever
        else
          warn '[woods-mcp] semantic search: disabled — set OPENAI_API_KEY, ' \
               'or run Ollama (brew install ollama && ollama serve)'
          nil
        end
      rescue StandardError => e
        warn "Note: Semantic search unavailable (#{e.message}). Using pattern-based search only."
        nil
      end

      # Check whether Ollama is reachable at the configured base URL.
      #
      # Uses a 500ms timeout so startup is not meaningfully delayed when Ollama
      # is absent. Probes /api/tags (the documented list-models endpoint) so any
      # running Ollama version responds. Treats any non-5xx response as reachable
      # — we only care whether something is listening, not whether the response
      # body is well-formed. Returns false on any network error or timeout.
      #
      # @return [Boolean]
      def self.ollama_reachable?
        require 'net/http'
        require 'uri'

        base_url = ENV.fetch('OLLAMA_BASE_URL', 'http://localhost:11434')
        uri = URI.parse(base_url)

        Net::HTTP.start(uri.host, uri.port,
                        open_timeout: 0.5, read_timeout: 0.5,
                        use_ssl: uri.scheme == 'https') do |http|
          response = http.get('/api/tags')
          !response.is_a?(Net::HTTPServerError)
        end
      rescue StandardError
        false
      end
    end
  end
end
