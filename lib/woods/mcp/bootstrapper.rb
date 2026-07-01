# frozen_string_literal: true

require 'json'

require_relative 'errors'
require_relative 'bootstrap_state'
require_relative 'config_resolver'
require_relative 'provider_probe'
require_relative '../index_artifact'
require_relative '../builder'
require_relative '../resolved_config'
require_relative '../storage/snapshotter'
require_relative '../storage/inapplicable_backend'

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
      #   2. If woods.json is present, resolve config from it; otherwise fall
      #      back to env-var auto-detect by default (pattern/structural mode when
      #      nothing is found). Set WOODS_REQUIRE_INDEX=1 to fail closed instead
      #      (raise MissingArtifact). See #138.
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
      #   credentials, dimension mismatch, unsupported artifact, or a missing
      #   artifact under WOODS_REQUIRE_INDEX=1).
      def self.build_retriever(index_dir: nil)
        state = BootstrapState.new
        state.mark(:hydrating)

        artifact = build_artifact(index_dir)
        config, _source = ConfigResolver.resolve(Woods.configuration,
                                                 artifact: artifact,
                                                 ollama_probe: method(:ollama_reachable?))
        return [nil, state] unless config.embedding_provider

        # Build the provider once so {ResolvedConfig.from_configuration} can
        # probe +provider.dimensions+ — without this, Ollama's runtime-only
        # dimension never makes it into +resolved+ and the downstream
        # Snapshotter.load_or_empty validation compares stored-vs-0.
        #
        # The probe is tolerant: if the provider is unreachable we still
        # need a non-nil +resolved+ so the MCP server can start degraded
        # (see the "provider unreachable" branch below). Snapshotter then
        # surfaces a DimensionMismatch only if there's actually a stored
        # artifact to validate against.
        resolved = build_resolved_config(config)
        state.resolved_config = resolved
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

      # Refresh a live retriever's in-memory stores from the latest dumps on
      # disk. Used by the MCP +reload+ tool so agents can pick up a fresh embed
      # run without restarting the process. The retriever instance is preserved
      # (tool closures kept their reference) — only the stores are mutated.
      #
      # No-op when:
      #   - +retriever+ is nil (no embedding provider configured)
      #   - stores are durable (pgvector / Qdrant auto-refresh externally)
      #   - +woods.json+ is absent (Shape-1 deployments don't use Snapshotter)
      #
      # @param retriever [Woods::Retriever, nil]
      # @param index_dir [String, Pathname]
      # @return [Hash] Stats — +{ vectors:, metadata:, graph: }+ record counts
      # @raise [Woods::MCP::BootstrapError] surfaced from ConfigResolver / Snapshotter
      def self.reload_stores!(retriever, index_dir:)
        return { vectors: 0, metadata: 0, graph: 0 } unless retriever

        artifact = build_artifact(index_dir)
        config, _source = ConfigResolver.resolve(Woods.configuration,
                                                 artifact: artifact,
                                                 ollama_probe: method(:ollama_reachable?))
        resolved = build_resolved_config(config)

        vectors_count = refill_in_memory_vector_store(retriever, config, resolved, artifact)
        metadata_count = refill_in_memory_metadata_store(retriever, config, resolved, artifact)
        graph_count = refill_in_memory_graph_store(retriever, config, artifact)

        # Context-cache entries from the previous embed run no longer agree
        # with the refreshed stores. Drop them so the next codebase_retrieve
        # call goes through the full pipeline with the new data. Embedding
        # caches (query → vector) survive — that mapping is deterministic
        # for a given provider+model.
        retriever.invalidate_context_cache! if retriever.respond_to?(:invalidate_context_cache!)

        { vectors: vectors_count, metadata: metadata_count, graph: graph_count }
      end

      # Retriever (and CachedRetriever) expose public +vector_store+ /
      # +metadata_store+ / +graph_store+ readers so this helper never pokes
      # private state. Durable backends don't implement +clear!+/+bulk_load+
      # — they return 0 silently because they're already refreshed externally.
      def self.refill_in_memory_vector_store(retriever, config, resolved, artifact)
        vs = retriever.respond_to?(:vector_store) ? retriever.vector_store : nil
        return 0 unless vs.respond_to?(:clear!) && vs.respond_to?(:bulk_load)

        fresh = hydrated_vector_store(config, resolved, artifact)
        return 0 unless fresh

        vs.clear!
        vs.bulk_load(fresh.each_entry.map { |id, vec, meta| { id: id, vector: vec, metadata: meta } })
        vs.respond_to?(:count) ? vs.count : 0
      end
      private_class_method :refill_in_memory_vector_store

      def self.refill_in_memory_metadata_store(retriever, config, resolved, artifact)
        ms = retriever.respond_to?(:metadata_store) ? retriever.metadata_store : nil
        return 0 unless ms.respond_to?(:clear!) && ms.respond_to?(:bulk_load)

        fresh = hydrated_metadata_store(config, resolved, artifact)
        return 0 unless fresh

        ms.clear!
        ms.bulk_load(fresh.each_entry)
        ms.respond_to?(:count) ? ms.count : 0
      end
      private_class_method :refill_in_memory_metadata_store

      # GraphStore::Memory doesn't expose a +clear!+/+bulk_load+ pair today
      # — a fresh run hands it an entirely new DependencyGraph from disk.
      # Swap the inner graph via +replace_graph+ so SearchExecutor / Ranker /
      # MCP tools keep their references to the same wrapper and see the new
      # graph (no closure references break).
      def self.refill_in_memory_graph_store(retriever, config, artifact)
        gs = retriever.respond_to?(:graph_store) ? retriever.graph_store : nil
        return 0 unless gs.respond_to?(:replace_graph)

        fresh = hydrated_graph_store(config, artifact)
        return 0 if fresh.nil?

        gs.replace_graph(fresh.graph)
        1
      end
      private_class_method :refill_in_memory_graph_store

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

      # Build a ResolvedConfig from the live host config, probing the
      # provider for its dimension when possible. A provider that can't
      # be reached (Ollama down) falls back to the declared-only path so
      # the MCP server can still come up degraded.
      def self.build_resolved_config(config)
        provider = Woods::Builder.new(config).build_embedding_provider
        ResolvedConfig.from_configuration(config, provider: provider)
      rescue StandardError
        ResolvedConfig.from_configuration(config)
      end
      private_class_method :build_resolved_config

      # Resolve an IndexArtifact from the passed dir or Woods.configuration.
      def self.build_artifact(index_dir)
        dir = index_dir || Woods.configuration.output_dir
        IndexArtifact.new(dir) if dir
      end
      private_class_method :build_artifact

      def self.build_retriever_from_config(config, resolved, artifact)
        vector_store = hydrated_vector_store(config, resolved, artifact)
        metadata_store = hydrated_metadata_store(config, resolved, artifact)
        graph_store = hydrated_graph_store(config, artifact)

        # Cross-populate the vector store's per-entry metadata cache from
        # the metadata store. The WVF1 binary format stores only id + float
        # blob (no per-vector hash) — it's numeric-only to keep dumps
        # mmap-friendly. The metadata lives in metadata.msgpack, and
        # InMemory::VectorStore#search uses its per-entry metadata for
        # filter predicates. Without this back-fill, a type-filtered
        # search returns zero results after a dump/reload.
        populate_vector_metadata(vector_store, metadata_store) if vector_store && metadata_store

        Woods::Builder.new(config).build_retriever(
          vector_store: vector_store, metadata_store: metadata_store,
          graph_store: graph_store
        )
      end
      private_class_method :build_retriever_from_config

      # Hydrate an in-memory graph store from +dependency_graph.json+ on disk.
      #
      # The Indexer doesn't populate the graph store — it accepts the kwarg,
      # dumps it empty at end of run, and moves on. But +dependency_graph.json+
      # is already written at extraction time with the full graph. Loading it
      # here via {DependencyGraph.from_h} turns the retriever's +:hybrid+
      # strategy from a silent no-op (empty graph → no graph expansion) into
      # a working graph-expansion source.
      #
      # Contract: this path assumes an ephemeral store. A durable backend
      # (adapter reports +durable? => true+) owns its own persistence and
      # must be populated via the extraction/embed write path — rebuilding
      # it from +dependency_graph.json+ on every boot would stomp state the
      # durable store is supposed to preserve. When a future adapter declares
      # itself durable, this method raises {Woods::Storage::InapplicableBackend}
      # so the contributor adding the adapter sees the contract violation at
      # boot rather than shipping a store that silently disagrees with
      # +dependency_graph.json+. Mirrors the pattern +Snapshotter::Vector.dump+
      # uses for pgvector / Qdrant.
      #
      # Returns nil when the artifact or dependency graph file is absent so
      # Builder falls back to a fresh empty store — the pre-fix behaviour for
      # hosts that haven't run an extraction yet.
      #
      # @param config [Woods::Configuration]
      # @param artifact [Woods::IndexArtifact, nil]
      # @return [Woods::Storage::GraphStore::Memory, nil]
      # @raise [Woods::Storage::InapplicableBackend] if the configured
      #   graph_store reports +durable? => true+
      def self.hydrated_graph_store(config, artifact)
        return nil unless artifact

        graph_json = artifact.output_dir.join('dependency_graph.json')
        return nil unless graph_json.exist?

        require_relative '../dependency_graph'
        require_relative '../storage/graph_store'

        probe = Woods::Builder.new(config).build_graph_store
        if probe.durable?
          raise Woods::Storage::InapplicableBackend,
                "graph_store=#{config.graph_store.inspect} reports durable? => true; " \
                'boot rehydration from dependency_graph.json is only valid for ephemeral ' \
                'stores. Populate the durable backend via the extraction write path instead.'
        end

        graph = Woods::DependencyGraph.from_h(JSON.parse(graph_json.read))
        Woods::Storage::GraphStore::Memory.new(graph)
      rescue Woods::Storage::InapplicableBackend
        raise
      rescue StandardError => e
        warn "[woods-mcp] graph hydration failed (#{e.class}: #{e.message}); starting with empty store"
        nil
      end
      private_class_method :hydrated_graph_store

      # Suffix the Indexer appends when a single unit is split into
      # multiple embedding vectors — see
      # {Embedding::Indexer#collect_embed_items}. Vector rows are keyed
      # per-chunk (+Foo#chunk_0+) but metadata is keyed by the base
      # identifier (+Foo+), so hydration strips the suffix before the
      # lookup. Mirrors the pattern in {Retriever} and
      # {Retrieval::ContextAssembler}.
      CHUNK_SUFFIX_PATTERN = /#chunk_\d+\z/
      private_constant :CHUNK_SUFFIX_PATTERN

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
          meta = metadata_store.find(id.to_s.sub(CHUNK_SUFFIX_PATTERN, ''))
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
