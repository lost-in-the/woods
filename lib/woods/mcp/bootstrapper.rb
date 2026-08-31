# frozen_string_literal: true

require 'json'

require_relative 'errors'
require_relative 'bootstrap_state'
require_relative 'config_resolver'
require_relative 'provider_probe'
require_relative '../index_artifact'
require_relative '../builder'
require_relative '../resolved_config'
require_relative '../generation'
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

        unless manifest_present?(dir)
          warn "Error: No manifest.json found in: #{dir}"
          warn 'Run `bundle exec rake woods:extract` in your Rails app first.'
          exit 1
        end

        dir
      end

      # Is there a manifest this index would resolve one from?
      #
      # A flat index (pre-payload, or never bumped) answers with
      # +manifest.json+ directly under +dir+. A payload-born index (#164
      # payloads) has none there — every artifact lives under the directory
      # +generation.json+'s +payload+ pointer names — so the pointer is
      # followed before concluding there is no index at all. Mirrors
      # {Woods::MCP::IndexReader#manifest_present?} exactly; keep the two in
      # agreement.
      #
      # @param dir [String] candidate index directory
      # @return [Boolean]
      def self.manifest_present?(dir)
        return true if File.exist?(File.join(dir, 'manifest.json'))

        generation = Woods::Generation.new(output_dir: dir)
        generation.payload_dir(generation.current).join('manifest.json').file?
      end
      private_class_method :manifest_present?

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
        if static_source_map_without_embeddings?(artifact)
          state.mark(:degraded, reason: Woods::Error.new('static source map has no embedding artifact'))
          return [nil, state]
        end
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
        retriever = build_retriever_from_config(config, resolved, artifact, state)
        probe_and_mark_state(config, state)
        derive_state_from_store_health(state)
        warn "[woods-mcp] semantic search: #{state.status} (#{config.embedding_provider})"

        [retriever, state]
      end

      def self.static_source_map_without_embeddings?(artifact)
        return false unless artifact

        generation = Woods::Generation.new(output_dir: artifact.output_dir)
        manifest_path = generation.payload_dir(generation.current).join('manifest.json')
        return false unless manifest_path.file?

        provenance = JSON.parse(Woods::AtomicFile.read(manifest_path))['provenance'] || {}
        provenance['mode'] == 'woods_static_ruby_source' && provenance['embeddings'] == 'absent'
      rescue JSON::ParserError, SystemCallError
        false
      end
      private_class_method :static_source_map_without_embeddings?

      # Refresh a live retriever's in-memory stores from the latest dumps on
      # disk. Used by the MCP +reload+ tool so agents can pick up a fresh embed
      # run without restarting the process.
      #
      # The transaction is build-then-swap (M7) — the old +clear!+ +
      # +bulk_load+ on the LIVE stores left an empty or half-loaded window a
      # concurrent reader could observe:
      #
      #   1. Build ALL candidate stores off-side against ONE captured
      #      generation. No lock is held; readers keep serving the old bundle.
      #   2. If ANY candidate fails: the reader is not reloaded and no store
      #      is swapped — the previous fully aligned generation stays served,
      #      the old retriever keeps answering, and a DISTINCT reload-phase
      #      degraded condition is recorded on +state+ (never the boot
      #      degraded state, which describes the old stores). Raised as
      #      {Woods::MCP::ReloadDegraded}.
      #   3. On success: acquire the exclusive generation lock (+reader+),
      #      RECHECK the generation — if it moved during candidate
      #      construction, {Woods::MCP::ReloadGenerationMoved} fails the
      #      attempt rather than swapping a stale bundle (the next +reload+
      #      is the rebuild) — then swap the store bundle with one
      #      assignment. In-flight readers finish against the retired
      #      stores; no reader ever observes empty or mixed stores.
      #   4. A successful reload clears the reload-failure condition.
      #
      # No-op when:
      #   - +retriever+ is nil (no embedding provider configured)
      #   - the live stores are durable (pgvector / Qdrant auto-refresh
      #     externally) — a partial all-or-nothing swap would mix backends
      #   - +woods.json+ is absent (Shape-1 deployments don't use Snapshotter)
      #
      # @param retriever [Woods::Retriever, Cache::CachedRetriever, nil]
      # @param index_dir [String, Pathname]
      # @param reader [Woods::MCP::IndexReader, nil] when given, the commit
      #   phase runs under the reader's exclusive generation lock and the
      #   reader's caches are reloaded alongside the swap
      # @param state [Woods::MCP::BootstrapState, nil] records the reload
      #   -phase degraded condition and its recovery
      # @return [Hash] Stats — +{ vectors:, metadata:, graph: }+ record counts
      # @raise [Woods::MCP::ReloadDegraded] the transaction aborted; nothing
      #   was swapped and the generation named by the error is still served
      def self.reload_stores!(retriever, index_dir:, reader: nil, state: nil)
        zero_counts = { vectors: 0, metadata: 0, graph: 0 }
        return zero_counts unless retriever

        target = swap_target(retriever)
        return zero_counts unless target

        artifact = build_artifact(index_dir)
        return zero_counts unless artifact

        generation = Woods::Generation.new(output_dir: artifact.output_dir)
        served = generation.current

        begin
          config, _source = ConfigResolver.resolve(Woods.configuration,
                                                   artifact: artifact,
                                                   ollama_probe: method(:ollama_reachable?))
        rescue StandardError => e
          raise ReloadDegraded.new(
            'reload could not resolve the index configuration; the previous generation is still ' \
            "being served: #{e.class}: #{e.message}",
            generation: served.number, stores: %w[vector metadata graph], error: e
          )
        end
        resolved = build_resolved_config(config)

        return zero_counts unless refreshable_stores?(target)

        # Phase 1: candidates off-side, against one captured generation.
        candidates = build_reload_candidates(config, resolved, artifact, served)
        return zero_counts unless candidates

        # Phase 2: recheck + one-assignment swap under the exclusive lock.
        commit_reload!(target, candidates, generation: generation, served: served,
                                           reader: reader, retriever: retriever, state: state)
      rescue Woods::MCP::ReloadDegraded => e
        state&.record_reload_failure(generation: e.generation, stores: e.stores,
                                     reason: "#{e.class}: #{e.message}")
        raise
      end

      # Reach the swappable retriever inside a (possibly cache-wrapped)
      # retriever. {Cache::CachedRetriever} keeps the real one in +@retriever+
      # and nothing else wraps today; the guarded ivar probe degrades to nil
      # on an unknown shape rather than raising mid-reload. Same rationale as
      # the retired +extract_ranker+ helper this replaces.
      def self.swap_target(retriever)
        return retriever if retriever.respond_to?(:swap_stores!)

        inner = (retriever.instance_variable_get(:@retriever) if retriever.instance_variable_defined?(:@retriever))
        inner if inner.respond_to?(:swap_stores!)
      end
      private_class_method :swap_target

      # Can this retriever's vector AND metadata stores both be refreshed
      # here? In-memory stores expose +clear!+/+bulk_load+; durable backends
      # (pgvector, Qdrant) don't implement +clear!+ — they're refreshed
      # externally. The transaction is all-or-nothing, so a shape that can't
      # refresh both takes the no-op rather than a partial swap.
      def self.refreshable_stores?(target)
        vs = target.vector_store
        ms = target.metadata_store
        vs.respond_to?(:clear!) && vs.respond_to?(:bulk_load) &&
          ms.respond_to?(:clear!) && ms.respond_to?(:bulk_load)
      end
      private_class_method :refreshable_stores?

      # Immutable candidate bundle built off-side. +graph_store+ is nil when
      # the index carries no +dependency_graph.json+ (the live graph is kept).
      ReloadCandidates = Struct.new(:vector_store, :metadata_store, :graph_store,
                                    :vector_count, :metadata_count, :graph_count,
                                    keyword_init: true)
      private_constant :ReloadCandidates

      # Build every candidate store against the captured generation. Any
      # failure raises {Woods::MCP::ReloadDegraded} naming the failing
      # component; nothing has been swapped at this point.
      #
      # Vector and metadata candidates must both exist (the transaction never
      # half-swaps); a nil graph candidate means "keep the live graph".
      def self.build_reload_candidates(config, resolved, artifact, served)
        vector = reload_vector_candidate(config, resolved, artifact, served)
        metadata = reload_metadata_candidate(config, resolved, artifact, served)
        return nil unless vector && metadata

        graph = reload_graph_candidate(config, artifact, served)

        # Back-fill the candidate vector store's per-entry metadata from the
        # candidate metadata store, OFF-SIDE before the swap. The WVF1 dump
        # persists id + floats only — without this, every type-filtered
        # search returns nothing after a reload (the boot path back-fills;
        # reload must too). Same contract as the boot-path call in
        # {.build_retriever_from_config}.
        populate_vector_metadata(vector, metadata)

        ReloadCandidates.new(
          vector_store: vector, metadata_store: metadata, graph_store: graph,
          vector_count: vector.count, metadata_count: metadata.count,
          graph_count: graph ? 1 : 0
        )
      end
      private_class_method :build_reload_candidates

      def self.reload_vector_candidate(config, resolved, artifact, served)
        hydrated_vector_store(config, resolved, artifact, nil, strict: true)
      rescue StandardError => e
        raise ReloadDegraded.new(
          "vector store refresh failed: #{e.class}: #{e.message}",
          generation: served.number, stores: [:vector], error: e
        )
      end
      private_class_method :reload_vector_candidate

      def self.reload_metadata_candidate(config, resolved, artifact, served)
        hydrated_metadata_store(config, resolved, artifact, nil, strict: true)
      rescue StandardError => e
        raise ReloadDegraded.new(
          "metadata store refresh failed: #{e.class}: #{e.message}",
          generation: served.number, stores: [:metadata], error: e
        )
      end
      private_class_method :reload_metadata_candidate

      def self.reload_graph_candidate(config, artifact, served)
        hydrated_graph_store(config, artifact, nil, strict: true)
      rescue StandardError => e
        raise ReloadDegraded.new(
          "graph store refresh failed: #{e.class}: #{e.message}",
          generation: served.number, stores: [:graph], error: e
        )
      end
      private_class_method :reload_graph_candidate

      # Commit phase: acquire the exclusive generation lock, RECHECK the
      # generation (a bump during candidate construction means the built
      # bundle is stale — swapping it would pair reader state from one
      # generation with stores from another), then swap the bundle with ONE
      # assignment and align the reader caches. All inside the lock, so no
      # tool handler can observe an intermediate state.
      def self.commit_reload!(target, candidates, generation:, served:, reader:, retriever:, state:)
        swap = lambda do
          current = generation.current
          unless same_generation_marker?(served, current)
            raise ReloadGenerationMoved.new(
              "index generation moved during reload (captured #{served.number}, now #{current.number}); " \
              'nothing was swapped and the previous generation is still being served — invoke reload again',
              generation: served.number, stores: %w[vector metadata graph]
            )
          end

          target.swap_stores!(
            vector_store: candidates.vector_store,
            metadata_store: candidates.metadata_store,
            graph_store: candidates.graph_store || target.graph_store
          )

          # Align the reader caches with the swapped bundle — the retired
          # generation's unit caches, identifier map and graph must not leak
          # into responses describing the new one.
          reader&.reload!

          # Context-cache entries from the previous embed run no longer agree
          # with the refreshed stores. Drop them so the next codebase_retrieve
          # call goes through the full pipeline with the new data. Embedding
          # caches (query → vector) survive — that mapping is deterministic
          # for a given provider+model. The Ranker needs no memo invalidation:
          # the swapped pipeline carries a FRESH ranker with no memoized
          # PageRank from the retired graph.
          retriever.invalidate_context_cache! if retriever.respond_to?(:invalidate_context_cache!)

          # Successful recovery clears the reload-phase degraded condition.
          state&.clear_reload_failure!

          { vectors: candidates.vector_count, metadata: candidates.metadata_count,
            graph: candidates.graph_count }
        end

        reader ? reader.with_exclusive_generation(&swap) : swap.call
      end
      private_class_method :commit_reload!

      # Token comparison, number fallback — mirrors IndexReader's
      # same_generation? rule (two collapsed bumps share a number but not a
      # token; pre-token generation files are told apart by number only).
      def self.same_generation_marker?(captured, current)
        return captured.number == current.number if captured.token.nil? || current.token.nil?

        captured.token == current.token
      end
      private_class_method :same_generation_marker?

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

      def self.build_retriever_from_config(config, resolved, artifact, state = nil)
        vector_store = hydrated_vector_store(config, resolved, artifact, state)
        metadata_store = hydrated_metadata_store(config, resolved, artifact, state)
        graph_store = hydrated_graph_store(config, artifact, state)

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
      # Resolved through {Woods::Generation#payload_dir}, same as every other
      # payload artifact reader: a payload-born index (#164 payloads) keeps
      # +dependency_graph.json+ only under +payloads/gen-N/+, never at the
      # index root, so reading the root path unconditionally hydrated an
      # empty graph and silently no-op'd PageRank / graph expansion. Resolves
      # to the root itself for a flat (pre-payload) index, so this is a no-op
      # change for every index that predates payloads.
      #
      # @param config [Woods::Configuration]
      # @param artifact [Woods::IndexArtifact, nil]
      # @param strict [Boolean] when true (reload candidate path), a soft
      #   failure RAISES instead of degrading to an empty store — a reload
      #   must never swap a good live store for an empty candidate (M7)
      # @return [Woods::Storage::GraphStore::Memory, nil]
      # @raise [Woods::Storage::InapplicableBackend] if the configured
      #   graph_store reports +durable? => true+
      def self.hydrated_graph_store(config, artifact, state = nil, strict: false)
        return nil unless artifact

        generation = Woods::Generation.new(output_dir: artifact.output_dir)
        graph_json = generation.payload_dir(generation.current).join('dependency_graph.json')
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

        # AtomicFile.read, never a bare Pathname#read (H1): a bare read tags
        # content with Encoding.default_external, and under LANG=C a graph
        # holding any non-ASCII identifier raised
        # Encoding::InvalidByteSequenceError — a locale bug that the M6
        # degraded-state honesty turned into a full retrieval outage.
        graph = Woods::DependencyGraph.from_h(JSON.parse(Woods::AtomicFile.read(graph_json)))
        Woods::Storage::GraphStore::Memory.new(graph)
      rescue Woods::Storage::InapplicableBackend
        raise
      rescue StandardError => e
        raise if strict

        warn "[woods-mcp] graph hydration failed (#{e.class}: #{e.message}); starting with empty store"
        state&.record_hydration_failure(:graph, e)
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
      # this path on boot. {.populate_reloaded_vector_metadata} reaches a
      # LIVE store directly, though, so the guard below still has to hold
      # even when +vector_store+ turns out to be a durable adapter.
      def self.populate_vector_metadata(vector_store, metadata_store)
        return unless implements_own?(vector_store, :each_entry) && vector_store.respond_to?(:store)
        return unless metadata_store.respond_to?(:find)

        # Collect (id, vector) pairs in one pass; overwriting via #store
        # re-triggers the metadata update path without changing the
        # underlying flat buffer (store semantics: same id → overwrite
        # vector + metadata in place).
        entries = vector_store.each_entry.map { |id, vec, _meta| [id, vec] }
        entries.each do |id, vec|
          meta = metadata_store.find(id.to_s.sub(CHUNK_SUFFIX_PATTERN, ''))
          next if meta.nil? || (meta.respond_to?(:empty?) && meta.empty?)

          vector_store.store(id, vec, vector_filter_metadata(meta))
        end
      end
      private_class_method :populate_vector_metadata

      # Does +object+ define +method_name+ itself, rather than merely
      # inheriting {Storage::VectorStore::Interface}'s default
      # {NotImplementedError} stub?
      #
      # Never test for this with a bare +respond_to?+ — the interface module
      # *defines* every method as a raising stub, so every adapter (including
      # pgvector/Qdrant, which implement +each_id+ but not +each_entry+)
      # answers +true+. That was B-108: {.populate_reloaded_vector_metadata}'s
      # guard used to be +respond_to?(:each_entry)+, which crashed the +reload+
      # tool the moment a durable backend was configured — +NotImplementedError+
      # is a +ScriptError+, which escapes every +rescue StandardError+ between
      # here and the stdio transport loop and killed the server. Mirrors
      # {Woods::Embedding::Indexer#implements_own?}.
      #
      # @param object [Object]
      # @param method_name [Symbol]
      # @return [Boolean]
      def self.implements_own?(object, method_name)
        return false unless object.respond_to?(method_name)
        return true unless defined?(Storage::VectorStore::Interface)

        object.method(method_name).owner != Storage::VectorStore::Interface
      end
      private_class_method :implements_own?

      # Reduce a metadata-store record to the SYMBOL-keyed subset the live
      # embed path writes per vector — see
      # {Embedding::Indexer#store_vectors}: +{ type:, identifier:, file_path: }+
      # — plus +namespace:+, which only the backfill can supply (the store
      # carries it per unit) and which namespace-filtered search after a
      # dump/reload depends on.
      #
      # The metadata store returns STRING-keyed records on every real
      # backend (SQLite round-trips through JSON.parse; InMemory stringifies
      # on store), while {Retrieval::SearchExecutor#build_vector_filters}
      # builds symbol-keyed filters and +VectorStore::InMemory#gather_candidates+
      # probes +meta[:type]+ directly. Back-filling the raw string-keyed
      # record therefore made every type-filtered +codebase_retrieve+ return
      # EMPTY on a dump-hydrated server (#150 item 5) — the live embed path
      # writes symbol keys, which is why in-process specs never saw it.
      # Nil fields are dropped rather than stored.
      #
      # @param meta [Hash] Metadata record (string- or symbol-keyed)
      # @return [Hash{Symbol => Object}] Symbol-keyed filter subset
      def self.vector_filter_metadata(meta)
        {
          type: meta['type'] || meta[:type],
          identifier: meta['identifier'] || meta[:identifier],
          file_path: meta['file_path'] || meta[:file_path],
          namespace: meta['namespace'] || meta[:namespace]
        }.compact
      end
      private_class_method :vector_filter_metadata

      # Return a hydrated InMemory vector store when Shape 2 applies
      # (in-memory configured + artifact on disk + resolved config) —
      # otherwise nil, which tells Builder to construct a fresh one.
      # Durable backends (pgvector, Qdrant) never match this path.
      #
      # A soft failure (transient I/O, corrupt dump) records the error on
      # +state+ so the boot status reflects store health instead of reporting
      # :hydrated over empty stores (M6). With +strict:+ (reload candidate
      # path) a soft failure raises instead — a reload must never swap a
      # good live store for an empty candidate (M7).
      def self.hydrated_vector_store(config, resolved, artifact, state = nil, strict: false)
        return nil unless artifact && resolved
        return nil unless config.vector_store == :in_memory

        Woods::Storage::Snapshotter::Vector.load_or_empty(artifact, resolved_config: resolved)
      rescue Woods::MCP::BootstrapError, ArgumentError
        # Config-invalid failures — ArgumentError signals a misconfigured
        # output_dir (dump_dir outside dumps_root) or a programming bug,
        # not a transient I/O issue. Operators must see these.
        raise
      rescue StandardError => e
        raise if strict

        warn "[woods-mcp] vector hydration failed (#{e.class}: #{e.message}); starting with empty store"
        state&.record_hydration_failure(:vector, e)
        nil
      end
      private_class_method :hydrated_vector_store

      def self.hydrated_metadata_store(config, resolved, artifact, state = nil, strict: false)
        return nil unless artifact && resolved
        return nil unless config.metadata_store == :in_memory

        Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact, resolved_config: resolved)
      rescue Woods::MCP::BootstrapError, ArgumentError
        raise
      rescue StandardError => e
        raise if strict

        warn "[woods-mcp] metadata hydration failed (#{e.class}: #{e.message}); starting with empty store"
        state&.record_hydration_failure(:metadata, e)
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

      # Derive the final boot status from store health (M6). Reaching the
      # provider is not enough to claim :hydrated: a hydration soft-failure
      # left empty in-memory stores, and a "healthy" status on top of them
      # presents a server that answers everything with nothing as fully
      # operational. Provider-unreachable degradations keep their reason;
      # only a false :hydrated is corrected.
      def self.derive_state_from_store_health(state)
        return unless state.hydration_failed? && state.status == :hydrated

        state.mark(:degraded, reason: state.hydration_failures.values.first)
      end
      private_class_method :derive_state_from_store_health
    end
  end
end
