# frozen_string_literal: true

require_relative 'errors'
require_relative 'bootstrap_state'
require_relative 'config_resolver'
require_relative 'provider_probe'
require_relative '../index_artifact'
require_relative '../resolved_config'
require_relative '../storage/snapshotter'

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

      # Build a retriever for MCP semantic search.
      #
      # Flow:
      #   1. Wrap output_dir in an IndexArtifact (owns path semantics).
      #   2. If woods.json is present, resolve config from it; otherwise
      #      either raise MissingArtifact or, if WOODS_ALLOW_AUTODETECT=1,
      #      fall back to env-var auto-detect (deprecated path).
      #   3. Build provider + stores from config (no mutation of
      #      Woods.configuration — the host's initializer stays intact).
      #   4. Hydrate in-memory stores from dumps (stubs in PR 2; real in PR 3).
      #   5. Probe the provider. If reachable, state :hydrated. If unreachable,
      #      state :degraded — retriever is still returned, queries will
      #      retry on first use.
      #
      # Config-invalid failures raise typed BootstrapError subclasses;
      # exe/woods-mcp's top-level catches them and prints a one-line
      # operator message. Dependency-unreachable failures start degraded
      # and surface via woods_status.
      #
      # @param index_dir [String, nil] Path to the extraction output directory.
      #   When nil, uses Woods.configuration.output_dir.
      # @return [Array(Woods::Retriever, Woods::MCP::BootstrapState)]
      # @raise [Woods::MCP::BootstrapError] on config-invalid (missing
      #   credentials, dimension mismatch, unsupported artifact, missing
      #   artifact with autodetect off).
      def self.build_retriever(index_dir: nil)
        state = BootstrapState.new
        state.mark(:hydrating)

        artifact = build_artifact(index_dir)
        config, _source = ConfigResolver.resolve(Woods.configuration,
                                                 artifact: artifact,
                                                 ollama_probe: method(:ollama_reachable?))
        return [nil, state] unless config.embedding_provider

        resolved = ResolvedConfig.from_configuration(config)
        retriever = build_retriever_from_config(config, resolved, artifact)
        probe_and_mark_state(config, state)
        warn "[woods-mcp] semantic search: #{state.status} (#{config.embedding_provider})"

        [retriever, state]
      end

      # Backwards-compatible wrapper — existing callers (exe/woods-mcp and
      # exe/woods-mcp-http) just want the retriever. They rescue typed
      # BootstrapError at their own top level; we do not catch here.
      def self.build_retriever_compat(index_dir: nil)
        retriever, _state = build_retriever(index_dir: index_dir)
        retriever
      end

      # Check whether Ollama is reachable at the configured base URL.
      #
      # Kept for backwards compatibility with existing specs. Delegates to
      # {Woods::MCP::ConfigResolver} and is passed as the +ollama_probe:+
      # callable in {.build_retriever} so that specs stubbing this method
      # continue to intercept Ollama checks in the autodetect path.
      #
      # New code should use {Woods::MCP::ProviderProbe.reachable!} via the
      # ResolvedConfig flow.
      #
      # @return [Boolean]
      def self.ollama_reachable?
        ConfigResolver.send(:ollama_reachable?)
      end

      # Resolve an IndexArtifact from the passed dir or Woods.configuration.
      def self.build_artifact(index_dir)
        dir = index_dir || Woods.configuration.output_dir
        IndexArtifact.new(dir) if dir
      end
      private_class_method :build_artifact

      def self.build_retriever_from_config(config, resolved, artifact)
        vector_store = hydrated_vector_store(config, resolved, artifact)
        metadata_store = hydrated_metadata_store(config, resolved, artifact)

        # Cross-populate the vector store's per-entry metadata cache from
        # the metadata store. The WVF1 binary format stores only id + float
        # blob (no per-vector hash) — it's numeric-only to keep dumps
        # mmap-friendly. The metadata lives in metadata.msgpack, and
        # InMemory::VectorStore#search uses its per-entry metadata for
        # filter predicates. Without this back-fill, a type-filtered
        # search returns zero results after a dump/reload.
        populate_vector_metadata(vector_store, metadata_store) if vector_store && metadata_store

        Woods::Builder.new(config).build_retriever(
          vector_store: vector_store, metadata_store: metadata_store
        )
      end
      private_class_method :build_retriever_from_config

      # Back-fill the vector store's per-entry metadata hashes from the
      # metadata store. Only makes sense when both are in-memory — durable
      # backends return nil from the hydration helpers and never reach
      # this path.
      def self.populate_vector_metadata(vector_store, metadata_store)
        return unless vector_store.respond_to?(:each_entry) && vector_store.respond_to?(:store)
        return unless metadata_store.respond_to?(:find)

        # Collect (id, vector) pairs in one pass; overwriting via #store
        # re-triggers the metadata update path without changing the
        # underlying flat buffer (store semantics: same id → overwrite
        # vector + metadata in place).
        entries = vector_store.each_entry.map { |id, vec, _meta| [id, vec] }
        entries.each do |id, vec|
          meta = metadata_store.find(id)
          next if meta.nil? || (meta.respond_to?(:empty?) && meta.empty?)

          vector_store.store(id, vec, meta)
        end
      end
      private_class_method :populate_vector_metadata

      # Return a hydrated InMemory vector store when Shape 2 applies
      # (in-memory configured + artifact on disk + resolved config) —
      # otherwise nil, which tells Builder to construct a fresh one.
      # Durable backends (pgvector, Qdrant) never match this path.
      def self.hydrated_vector_store(config, resolved, artifact)
        return nil unless artifact && resolved
        return nil unless config.vector_store == :in_memory

        Woods::Storage::Snapshotter::Vector.load_or_empty(artifact, resolved_config: resolved)
      rescue Woods::MCP::BootstrapError, ArgumentError
        # Config-invalid failures — ArgumentError signals a misconfigured
        # output_dir (dump_dir outside dumps_root) or a programming bug,
        # not a transient I/O issue. Operators must see these.
        raise
      rescue StandardError => e
        warn "[woods-mcp] vector hydration failed (#{e.class}: #{e.message}); starting with empty store"
        nil
      end
      private_class_method :hydrated_vector_store

      def self.hydrated_metadata_store(config, resolved, artifact)
        return nil unless artifact && resolved
        return nil unless config.metadata_store == :in_memory

        Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact, resolved_config: resolved)
      rescue Woods::MCP::BootstrapError, ArgumentError
        raise
      rescue StandardError => e
        warn "[woods-mcp] metadata hydration failed (#{e.class}: #{e.message}); starting with empty store"
        nil
      end
      private_class_method :hydrated_metadata_store

      def self.probe_and_mark_state(config, state)
        provider = Woods::Builder.new(config).build_embedding_provider
        ProviderProbe.reachable!(provider)
        state.mark(:hydrated)
      rescue ProviderUnreachable => e
        state.mark(:degraded, reason: e)
        warn "[woods-mcp] provider unreachable at boot: #{e.url} (#{e.reason}); " \
             'starting degraded — will retry on first query'
      end
      private_class_method :probe_and_mark_state
    end
  end
end
