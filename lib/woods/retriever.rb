# frozen_string_literal: true

# Ruby 3.2 autoloads Set, but the gem supports >= 3.0 — make the require
# explicit so +filter_by_type+ works on the whole supported range.
require 'set'

require_relative 'retrieval/query_classifier'
require_relative 'retrieval/search_executor'
require_relative 'retrieval/ranker'
require_relative 'retrieval/context_assembler'
require_relative 'embedding/token_counter'
require_relative 'token_utils'

module Woods
  # Raised by {Retriever#retrieve} when +query+ fails the validation
  # boundary at the top of the pipeline: nil, blank, non-String, or over
  # {Retriever::MAX_QUERY_BYTES}. One shared boundary for every strategy
  # (keyword/vector/graph/hybrid) — pre-fix, a blank query surfaced as a
  # raw provider ArgumentError, and only on the vector path; the other
  # strategies tolerated it silently, and an oversized query went to the
  # provider verbatim to fail as an opaque 400.
  class InvalidQueryError < Error; end

  # Retriever orchestrates the full retrieval pipeline: classify, execute,
  # rank, and assemble context from a natural language query.
  #
  # Coordinates four internal components:
  # - {Retrieval::QueryClassifier} — determines intent, scope, target type
  # - {Retrieval::SearchExecutor} — maps classification to search strategy
  # - {Retrieval::Ranker} — re-ranks candidates with weighted signals
  # - {Retrieval::ContextAssembler} — builds token-budgeted context string
  #
  # Optionally builds a structural context overview (codebase unit counts
  # by type) that is prepended to the assembled context.
  #
  # @example
  #   retriever = Woods::Retriever.new(
  #     vector_store: vector_store,
  #     metadata_store: metadata_store,
  #     graph_store: graph_store,
  #     embedding_provider: embedding_provider
  #   )
  #   result = retriever.retrieve("How does the User model work?")
  #   result.context        # => "Codebase: 42 units (10 models, ...)\n\n---\n\n## User (model)..."
  #   result.strategy       # => :vector
  #   result.tokens_used    # => 4200
  #
  class Retriever # rubocop:disable Metrics/ClassLength
    # BERT / WordPiece-family embedders Ollama commonly serves. Matched
    # against `provider.model_name` to decide whether to use the 1.5
    # chars/token ratio and wire in an exact {Woods::Embedding::TokenCounter}.
    # Extend this list when new WordPiece-family models become popular —
    # the tiktoken 4.0 default remains the safe fallback for unknowns.
    OLLAMA_EMBEDDING_MODELS = Regexp.union(
      /\Anomic-embed/, /\Abge-/, /\Amxbai-embed/,
      /\Asnowflake-arctic/, /\Aall-minilm/, /\Aparaphrase-/,
      /\Ae5-/, /\Agte-/, /\Astella/,
      /\Agranite-embedding/, /\Ajina-embeddings/
    ).freeze

    # Diagnostic trace for retrieval quality analysis.
    #
    # +skipped_missing_metadata+ carries {Retrieval::ContextAssembler}'s count
    # of candidates dropped because the metadata store had no record for
    # their identifier (a stale vector). See +RetrievalResult+'s docstring
    # for how callers should read it alongside +sources+.
    RetrievalTrace = Struct.new(:classification, :strategy, :candidate_count,
                                :ranked_count, :tokens_used, :elapsed_ms,
                                :skipped_missing_metadata,
                                keyword_init: true)

    # The result of a retrieval operation.
    #
    # When the caller passed +types:+ to +#retrieve+, +type_rank_context+
    # is a Hash keyed by requested type name with one entry per type:
    #
    #   {
    #     "controller" => {
    #       source: :in_top_k,            # see enum below
    #       top_of_type_global_rank: 3,   # 1-based rank in unfiltered ranked, or nil
    #       global_k: 20,                 # size of the unfiltered ranked list
    #       total_of_type: 183            # total units of that type in the index
    #     }
    #   }
    #
    # +:source+ tells the caller which bucket the type landed in without
    # forcing them to infer it from nil ranks:
    #   :in_top_k              — type present in the unfiltered ranked list;
    #                            strong match.
    #   :within_type_fallback  — type NOT in the unfiltered ranked list, but
    #                            the fallback vector search returned
    #                            candidates of this type. Weak match.
    #   :outside_top_k         — type NOT in the unfiltered ranked list, has
    #                            units in the index, but the fallback did
    #                            not run (other requested types filled the
    #                            result). No results of this type.
    #   :absent                — type has zero units in the index.
    #
    # Nil for unfiltered queries.
    RetrievalResult = Struct.new(:context, :sources, :classification, :strategy, :tokens_used, :budget, :trace,
                                 :type_rank_context, keyword_init: true)

    # Raised when a metadata-store access fails during retrieval (M8). One
    # shared typed error for every store call site: the retriever used to
    # swallow these into misleading answers — +types:+ queries reported
    # +:absent+, the rank-within-type fallback short-circuited to empty, and
    # exclusion filtering silently no-op'd, each presenting a broken store as
    # a clean empty result. Raising here lets the MCP server map the failure
    # to tool-visible degraded metadata instead.
    class StoreError < Error
      # @return [String] which store failed (e.g. +"metadata"+)
      attr_reader :store

      # @param message [String] includes the underlying error class and message
      # @param store [Symbol, String] the failing store component
      def initialize(message, store: :metadata)
        super(message)
        @store = store.to_s
      end
    end

    # Store adapter wrapper that turns ANY failure of a store call into the
    # shared typed {StoreError}, naming the store that failed.
    #
    # M8 wrapped the three lookups the Retriever performs itself, but the
    # store reads carrying most of the query traffic happen INSIDE the
    # pipeline components — the ranker's and assembler's +find_batch+, and
    # every executor store call. Those escaped raw: the SDK reported
    # "Internal error calling tool codebase_retrieve", or {MCP::ToolContract}
    # saw an IO-flavored cause and relabeled it +corrupt_artifact+ ("An Index
    # artifact is unavailable or malformed") — the wrong diagnosis for, say, a
    # SQLite metadata DB deleted mid-serve (MCP-6).
    #
    # Only the pipeline COMPONENTS get facades. The Pipeline struct's store
    # members and the public +vector_store+ / +metadata_store+ / +graph_store+
    # readers keep the raw adapters, so the reload transaction's capability
    # and store-type checks ({MCP::Bootstrapper.refreshable_stores?},
    # +implements_own?+) still see the real objects.
    class TranslatedStore
      # @param store [Object] the wrapped adapter
      # @param name [Symbol] store component name (+:vector+, +:metadata+, +:graph+)
      def initialize(store, name)
        @store = store
        @name = name
      end

      # @return [Object] the wrapped adapter, for callers that need identity
      attr_reader :store

      def respond_to_missing?(name, include_private = false)
        @store.respond_to?(name, include_private) || super
      end

      def method_missing(name, ...)
        return super unless @store.respond_to?(name)

        @store.public_send(name, ...)
      rescue StoreError
        raise
      rescue StandardError => e
        raise StoreError.new("#{@name} store call #{name} failed: #{e.class}: #{e.message}", store: @name)
      end
    end

    # Unit types queried for the structural context overview.
    STRUCTURAL_TYPES = %w[model controller service job mailer component graphql].freeze

    # Immutable retrieval pipeline captured per store bundle. Every component
    # that references a store lives here, so swapping the bundle is ONE
    # assignment: {#swap_stores!} replaces +@pipeline+ and every query
    # resolves the pipeline once at the top of {#retrieve}. An in-flight query
    # keeps the struct it resolved and finishes entirely against the old
    # stores; a new query sees only the complete new bundle (M7 — build-then-
    # swap, never clear!+bulk_load on live stores).
    Pipeline = Struct.new(:executor, :ranker, :assembler,
                          :vector_store, :metadata_store, :graph_store,
                          keyword_init: true)
    private_constant :Pipeline

    # The live store handles. These delegate to the current pipeline —
    # callers that want store contents read through these accessors, exactly
    # as before; the difference is that a swap retires the old store objects
    # instead of mutating them in place.
    def vector_store   = @pipeline.vector_store
    def metadata_store = @pipeline.metadata_store
    def graph_store    = @pipeline.graph_store

    # Read-only view of the current store bundle and the components wired to
    # it (executor, ranker, assembler). Diagnostics/specs used to poke
    # +@executor+/-style ivars directly; this is the supported equivalent.
    # The reload transaction swaps the whole struct via {#swap_stores!}.
    #
    # @return [Pipeline]
    attr_reader :pipeline

    # Optional callback invoked with the pipeline struct the moment
    # {#retrieve} resolves it, before any pipeline work runs. Nil in
    # production. Observability seam for the reload transaction's old-or-new
    # guarantee (M7): a test can block an in-flight query AFTER it captured
    # the old bundle but BEFORE the swap lands, deterministically.
    #
    # @return [Proc, nil]
    attr_accessor :pipeline_observer

    # @param vector_store [Storage::VectorStore::Interface] Vector store adapter
    # @param metadata_store [Storage::MetadataStore::Interface] Metadata store adapter
    # @param graph_store [Storage::GraphStore::Interface] Graph store adapter
    # @param embedding_provider [Embedding::Provider::Interface] Embedding provider
    # @param formatter [#call, nil] Optional callable to post-process the context string
    def initialize(vector_store:, metadata_store:, graph_store:, embedding_provider:, formatter: nil)
      @embedding_provider = embedding_provider
      @formatter = formatter
      @classifier = Retrieval::QueryClassifier.new
      @pipeline = build_pipeline(vector_store: vector_store,
                                 metadata_store: metadata_store,
                                 graph_store: graph_store)
    end

    # Replace the store bundle atomically (M7).
    #
    # Builds a complete new pipeline from +stores+ (fresh executor, ranker and
    # assembler — a fresh ranker also carries no memoized PageRank from the
    # retired graph) and swaps it in with a single assignment. Queries already
    # running resolved the old pipeline and finish against the old stores;
    # queries started afterwards resolve the new bundle. No query can observe
    # an empty or half-swapped store set, because no store is ever mutated in
    # place.
    #
    # Called by the MCP reload transaction AFTER its candidate stores passed
    # the generation recheck, under the exclusive swap lock.
    #
    # @param vector_store [Storage::VectorStore::Interface]
    # @param metadata_store [Storage::MetadataStore::Interface]
    # @param graph_store [Storage::GraphStore::Interface]
    # @return [self]
    def swap_stores!(vector_store:, metadata_store:, graph_store:)
      @pipeline = build_pipeline(vector_store: vector_store,
                                 metadata_store: metadata_store,
                                 graph_store: graph_store)
      self
    end

    # Build one immutable pipeline around a store bundle.
    #
    # Components read through {TranslatedStore} facades so every store call
    # they make raises the typed {StoreError} instead of a raw adapter error
    # (MCP-6); the struct keeps the raw adapters for identity and capability
    # checks.
    def build_pipeline(vector_store:, metadata_store:, graph_store:)
      translated_vector = translate_store(vector_store, :vector)
      translated_metadata = translate_store(metadata_store, :metadata)
      translated_graph = translate_store(graph_store, :graph)

      Pipeline.new(
        executor: Retrieval::SearchExecutor.new(
          vector_store: translated_vector,
          metadata_store: translated_metadata,
          graph_store: translated_graph,
          embedding_provider: @embedding_provider
        ),
        ranker: Retrieval::Ranker.new(metadata_store: translated_metadata, graph_store: translated_graph),
        assembler: Retrieval::ContextAssembler.new(
          metadata_store: translated_metadata,
          chars_per_token: infer_chars_per_token(@embedding_provider),
          token_counter: infer_token_counter(@embedding_provider)
        ),
        vector_store: vector_store,
        metadata_store: metadata_store,
        graph_store: graph_store
      )
    end
    private :build_pipeline

    # Wrap one store adapter for the pipeline components. Nil stays nil — a
    # nil graph store is a supported bundle shape.
    def translate_store(store, name)
      store && TranslatedStore.new(store, name)
    end
    private :translate_store

    # Infer the chars-per-token ratio from an embedding provider's model.
    # Ollama WordPiece-style tokenizers (nomic-embed-text, bge-*,
    # mxbai-embed-*, snowflake-arctic-*) run hotter on Ruby source than
    # tiktoken; 1.5 is the project's calibrated value — see
    # {Woods::Builder#chars_per_token_for} and docs/EMBEDDING_MODELS.md.
    #
    # @param provider [Object, nil]
    # @return [Float]
    def infer_chars_per_token(provider)
      return Retrieval::ContextAssembler::DEFAULT_CHARS_PER_TOKEN unless provider.respond_to?(:model_name)

      model = provider.model_name.to_s
      ollama_patterns = OLLAMA_EMBEDDING_MODELS
      model.match?(ollama_patterns) ? TokenUtils.chars_per_token_for(:ollama) : Retrieval::ContextAssembler::DEFAULT_CHARS_PER_TOKEN
    end
    private :infer_chars_per_token

    # Build an exact TokenCounter for the Ollama path — where WordPiece
    # ratios vary widely across Rails source, so an exact tokenizer is the
    # only way to keep context-budget truncation honest. For OpenAI (and
    # unknown providers) tiktoken's 4.0 ratio is stable enough that the
    # heuristic fallback is fine; we skip the counter there so we don't
    # pull in the optional `tokenizers` gem or warn about it at boot.
    #
    # @param provider [Object, nil]
    # @return [Woods::Embedding::TokenCounter, nil]
    def infer_token_counter(provider)
      return nil unless provider.respond_to?(:model_name)

      model = provider.model_name.to_s
      ollama_patterns = OLLAMA_EMBEDDING_MODELS
      return nil unless model.match?(ollama_patterns)

      Embedding::TokenCounter.new
    end
    private :infer_token_counter

    # Unit types excluded from retrieval by default. +test_mapping+ units
    # make up ~33% of a typical index and lexically dominate semantic rank
    # for production queries ("stripe webhook" often surfaces
    # stripe_webhook_spec.rb above the actual controller). Callers can
    # override by passing +types:+ (include-only) or an explicit +exclude_types:+.
    DEFAULT_EXCLUDE_TYPES = %w[test_mapping].freeze

    # Suffix the Indexer appends when a single unit is split into multiple
    # embedding vectors — see {Embedding::Indexer#collect_embed_items}. The
    # metadata store is keyed by the base identifier only, so the fallback
    # lookup in +candidate_type+ strips this before probing. Mirrors the
    # constant in {Retrieval::ContextAssembler}; kept as a local copy so the
    # two consumers can evolve independently if the chunk format ever
    # changes on one side of the pipeline.
    CHUNK_SUFFIX_PATTERN = /#chunk_\d+\z/
    private_constant :CHUNK_SUFFIX_PATTERN

    # Maximum query size accepted by {#retrieve}, in bytes.
    #
    # Configuration/ResolvedConfig have no existing query-length knob
    # (checked both) — +max_context_tokens+ bounds assembled OUTPUT
    # context, not the input query. ~8KB comfortably covers any
    # legitimate natural-language query and fails fast, in-process,
    # instead of round-tripping an oversized string to an embedding or
    # metadata provider just to get a 400 back.
    MAX_QUERY_BYTES = 8 * 1024

    # Execute the full retrieval pipeline for a natural language query.
    #
    # Pipeline: classify -> execute -> rank -> filter -> (fallback within-type
    # when filter emptied everything) -> assemble -> format.
    #
    # When +types:+ is set, the response carries +type_rank_context+ —
    # per-type rank metadata the caller uses to tell a strong match from
    # a weak one without Woods imposing a score threshold.
    #
    # @param query [String] Natural language query
    # @param budget [Integer] Token budget for context assembly
    # @param types [Array<String, Symbol>, nil] If set, restrict results to these
    #   unit types (overrides DEFAULT_EXCLUDE_TYPES).
    # @param exclude_types [Array<String, Symbol>, nil] Additional types to
    #   exclude. Applied on top of DEFAULT_EXCLUDE_TYPES unless +types:+ is set.
    # @return [RetrievalResult] Complete retrieval result
    def retrieve(query, budget: 8000, types: nil, exclude_types: nil)
      validate_query!(query)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # One atomic read of the bundle reference: everything this query does
      # from here on — execution, ranking, filtering, assembly — stays on the
      # SAME store set even if a reload swaps the pipeline mid-flight (M7).
      pipeline = @pipeline
      @pipeline_observer&.call(pipeline)
      classification = @classifier.classify(query)
      execution_result = pipeline.executor.execute(query: query, classification: classification)
      ranked = pipeline.ranker.rank(execution_result.candidates, classification: classification)

      type_list = normalize_type_list(types)
      filtered, fallback_ran = apply_type_filter(pipeline, ranked, query, classification,
                                                 types: types, type_list: type_list,
                                                 exclude_types: exclude_types)
      type_rank_context = build_type_rank_context_for(ranked, pipeline, type_list, filtered,
                                                      fallback_ran: fallback_ran)

      assembled = assemble_context(pipeline, filtered, classification, budget)
      trace = build_trace(classification, execution_result, filtered, assembled, start_time)

      build_result(
        assembled: assembled, classification: classification, strategy: execution_result.strategy,
        budget: budget, trace: trace, type_rank_context: type_rank_context
      )
    end

    private

    # Validate +query+ before any classify/execute/rank work happens.
    #
    # @param query [Object] The caller-supplied query
    # @raise [InvalidQueryError] nil, non-String, blank, or over {MAX_QUERY_BYTES}
    # @return [void]
    def validate_query!(query)
      raise InvalidQueryError, "query must be a String, got #{query.class}" unless query.is_a?(String)
      raise InvalidQueryError, 'query cannot be blank' if query.strip.empty?
      return unless query.bytesize > MAX_QUERY_BYTES

      raise InvalidQueryError, "query exceeds max size of #{MAX_QUERY_BYTES} bytes (got #{query.bytesize})"
    end

    # Filter ranked candidates by type, using an include-list when +types+
    # is set and an exclude-list otherwise (default: +DEFAULT_EXCLUDE_TYPES+,
    # extended by any +exclude_types+ the caller adds).
    #
    # Candidate type comes from either the metadata store (when populated)
    # or the candidate's inline +metadata+ hash — both are probed so the
    # filter still works on graph-expansion candidates that carry no
    # vector-store metadata.
    #
    # @param pipeline [Pipeline] the store bundle this query resolved (M7:
    #   every store access in the query flows from this snapshot)
    # @param candidates [Array<Candidate>]
    # @param types [Array<String, Symbol>, nil]
    # @param exclude_types [Array<String, Symbol>, nil]
    # @return [Array<Candidate>]
    def filter_by_type(pipeline, candidates, types:, exclude_types:)
      allowed = normalize_type_list(types)
      return candidates.select { |c| allowed.include?(candidate_type(pipeline, c)) } if allowed

      # DEFAULT_EXCLUDE_TYPES is always non-empty, so `excluded` here can
      # never be empty — no early-return-candidates-unchanged branch exists.
      excluded = (normalize_type_list(exclude_types) || Set.new) | DEFAULT_EXCLUDE_TYPES.to_set
      candidates.reject { |c| excluded.include?(candidate_type(pipeline, c)) }
    end

    def normalize_type_list(list)
      return nil if list.nil? || list.empty?

      list.to_set(&:to_s)
    end

    def candidate_type(pipeline, candidate)
      inline = type_from_hash(candidate.metadata)
      return inline if inline

      # Fall back to the metadata store lookup so graph-expansion candidates
      # (which come in with metadata: {}) still get type-filtered. Strip the
      # chunk suffix first: chunked vector hits arrive with +Foo#chunk_0+
      # but the store is keyed by the base identifier +Foo+ only, and a
      # missed lookup would let the candidate past the default-exclude
      # (type resolves to '', which +excluded+ never contains).
      lookup_id = candidate.identifier.to_s.sub(CHUNK_SUFFIX_PATTERN, '')
      type_from_hash(pipeline.metadata_store.find(lookup_id)) || ''
    rescue StandardError => e
      # M8: a failed lookup must not read as "type is ''" — that silently
      # disables exclusion filtering. Raise the shared typed store error.
      raise StoreError,
            "metadata store lookup failed while resolving a candidate type: #{e.class}: #{e.message}"
    end

    def type_from_hash(hash)
      return nil unless hash

      value = hash[:type] || hash['type']
      value&.to_s
    end

    # Assemble token-budgeted context from ranked candidates.
    #
    # @param pipeline [Pipeline] the resolved store bundle
    # @param ranked [Array<Candidate>] Ranked search candidates
    # @param classification [QueryClassifier::Classification] Query classification
    # @return [AssembledContext]
    def assemble_context(pipeline, ranked, classification, budget)
      pipeline.assembler.assemble(
        candidates: ranked,
        classification: classification,
        structural_context: build_structural_context(pipeline.metadata_store),
        budget: budget
      )
    end

    # Build a RetrievalResult from assembled context and pipeline metadata.
    #
    # @param assembled [AssembledContext] Assembled context
    # @param classification [QueryClassifier::Classification] Query classification
    # @param strategy [Symbol] Search strategy used
    # @param budget [Integer] Token budget
    # @return [RetrievalResult]
    def build_result(assembled:, classification:, strategy:, budget:, trace: nil, type_rank_context: nil)
      context = @formatter ? @formatter.call(assembled.context) : assembled.context
      context = append_type_rank_context(context, type_rank_context) if type_rank_context

      RetrievalResult.new(
        context: context,
        sources: assembled.sources,
        classification: classification,
        strategy: strategy,
        tokens_used: assembled.tokens_used,
        budget: budget,
        trace: trace,
        type_rank_context: type_rank_context
      )
    end

    # Post-rank reject, with rank-within-type fallback when the caller
    # passed a type filter and the global top-K had no candidate of the
    # requested type(s). Returns +[filtered, fallback_ran]+ — the second
    # element drives the :source field on type_rank_context.
    def apply_type_filter(pipeline, ranked, query, classification, types:, type_list:, exclude_types:)
      filtered = filter_by_type(pipeline, ranked, types: types, exclude_types: exclude_types)
      return [filtered, false] unless type_list && filtered.empty?

      [within_type_fallback(pipeline, query, classification, type_list, exclude_types), true]
    end

    # Rank-within-type fallback query. Pushes the explicit type filter
    # into the executor so the vector store only scores candidates of
    # that type. Used when the global top-K had none of the requested
    # types but the index may still contain them.
    #
    # Forces +strategy: :vector+. Only the vector path honors
    # +type_filter+ — on a keyword/graph/direct-classified query the
    # default strategy would ignore the filter, return the same
    # candidates, and silently leave +filtered+ empty. Vector search
    # works for any classification because we always have the raw
    # query text.
    #
    # Short-circuits to an empty Array when every requested type has
    # zero units in the index — there is nothing for the fallback to
    # find, so we skip the extra vector search.
    def within_type_fallback(pipeline, query, classification, type_list, exclude_types)
      type_array = type_list.to_a
      return [] if type_array.all? { |t| total_of_type(pipeline.metadata_store, t).to_i.zero? }

      fallback = pipeline.executor.execute(
        query: query, classification: classification,
        type_filter: type_array, strategy: :vector
      )
      ranked = pipeline.ranker.rank(fallback.candidates, classification: classification)
      filter_by_type(pipeline, ranked, types: type_array, exclude_types: exclude_types)
    end

    def build_trace(classification, execution_result, filtered, assembled, start_time)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)
      RetrievalTrace.new(
        classification: classification,
        strategy: execution_result.strategy,
        candidate_count: execution_result.candidates.size,
        ranked_count: filtered.size,
        tokens_used: assembled.tokens_used,
        elapsed_ms: elapsed_ms,
        skipped_missing_metadata: assembled.skipped_missing_metadata.to_i
      )
    end

    # Per-type rank metadata for +types:+ queries; nil on unfiltered queries.
    #
    # @param ranked [Array<Candidate>]
    # @param pipeline [Pipeline] the resolved store bundle (M7)
    # @param type_list [Set<String>, nil]
    # @param filtered [Array<Candidate>] The post-fallback candidate list
    # @param fallback_ran [Boolean] Whether rank-within-type fallback ran
    # @return [Hash{String => Hash}, nil]
    def build_type_rank_context_for(ranked, pipeline, type_list, filtered, fallback_ran:)
      return nil unless type_list

      build_type_rank_context(ranked, pipeline.metadata_store, type_list, filtered,
                              fallback_ran: fallback_ran)
    end

    # Build per-type rank metadata from the unfiltered global ranked list.
    #
    # +top_of_type_global_rank+ is the 1-based position of the first
    # candidate of that type in the ranked list, or nil when no candidate
    # of that type survived ranking. +total_of_type+ is the canonical
    # count from the metadata store — answers "does this type exist in the
    # index at all?" independent of query match. +source+ labels the bucket
    # the type landed in so the caller doesn't infer it from a nil rank;
    # see the RetrievalResult docstring for the four-value enum.
    #
    # @param ranked [Array<Candidate>]
    # @param metadata_store [Storage::MetadataStore::Interface] the resolved
    #   bundle's metadata store (M7)
    # @param type_list [Set<String>]
    # @param filtered [Array<Candidate>] The post-fallback candidate list
    #   {#retrieve} is about to assemble — used to confirm the fallback
    #   actually surfaced a candidate OF this specific type, not just that
    #   fallback ran.
    # @param fallback_ran [Boolean] Whether rank-within-type fallback ran
    # @return [Hash{String => Hash}]
    def build_type_rank_context(ranked, metadata_store, type_list, filtered, fallback_ran:)
      global_k = ranked.size
      type_list.to_h do |type|
        match_index = ranked.index { |c| candidate_type_from(metadata_store, c) == type }
        top_rank = match_index ? match_index + 1 : nil
        total = total_of_type(metadata_store, type)
        [
          type,
          {
            source: type_source(top_rank, total, metadata_store, filtered, type, fallback_ran: fallback_ran),
            top_of_type_global_rank: top_rank,
            global_k: global_k,
            total_of_type: total
          }
        ]
      end
    end

    # Pick the :source enum value for a single type based on where its
    # candidate ended up. See RetrievalResult's docstring for the enum.
    #
    # +:within_type_fallback+ requires the fallback to have actually
    # returned a candidate of THIS type — a multi-type fallback (e.g.
    # +types: %w[service mailer]+) can run and surface candidates for only
    # some of the requested types, and the type(s) it missed are
    # +:outside_top_k+, not falsely reported as a weak fallback match.
    def type_source(top_rank, total, metadata_store, filtered, type, fallback_ran:)
      return :in_top_k if top_rank
      return :absent if total.to_i.zero?
      return :within_type_fallback if fallback_ran && filtered.any? do |c|
        candidate_type_from(metadata_store, c) == type
      end

      :outside_top_k
    end

    def total_of_type(metadata_store, type)
      metadata_store.find_by_type(type).size
    rescue StandardError => e
      # M8: a failed count must not read as zero — that reports :absent for
      # a type that may exist and short-circuits the within-type fallback.
      raise StoreError,
            "metadata store count failed for type #{type.inspect}: #{e.class}: #{e.message}"
    end

    # Chunk-suffix-stripping candidate-type probe against an explicit
    # metadata store. Same lookup rules as {#candidate_type}; takes the
    # store as an argument so a caller holding a resolved bundle snapshot
    # (M7) probes the generation it started on.
    def candidate_type_from(metadata_store, candidate)
      inline = type_from_hash(candidate.metadata)
      return inline if inline

      lookup_id = candidate.identifier.to_s.sub(CHUNK_SUFFIX_PATTERN, '')
      type_from_hash(metadata_store.find(lookup_id)) || ''
    rescue StandardError => e
      raise StoreError,
            "metadata store lookup failed while resolving a candidate type: #{e.class}: #{e.message}"
    end

    # Append a compact markdown summary of +type_rank_context+ to the
    # assembled context string. Machine-readable enough for agents to
    # parse without a structured response channel. :source is the first
    # column so the common "strong match" case (in_top_k) is visible at
    # a glance without needing to reason about rank vs global_k.
    def append_type_rank_context(context, type_rank_context)
      return context if type_rank_context.empty?

      lines = ['', '### Type rank context', '',
               '| Type | Source | Rank in unfiltered top-K | Global K | Total in index |',
               '|------|--------|--------------------------|----------|----------------|']
      type_rank_context.each do |type, info|
        rank = info[:top_of_type_global_rank] || '—'
        total = info[:total_of_type].nil? ? '?' : info[:total_of_type]
        lines << "| #{type} | #{info[:source]} | #{rank} | #{info[:global_k]} | #{total} |"
      end
      "#{context}\n#{lines.join("\n")}\n"
    end

    # Build a structural context overview from the metadata store.
    #
    # Reports +searchable_entries+ (the retriever's native denominator:
    # one row per vector, including per-chunk rows for long units) rather
    # than +units_indexed+. The two differ because chunking duplicates
    # units; see the `structure` tool's glossary for the full picture.
    #
    # The banner ends with a pointer to `structure` so operators who
    # spot the searchable-entries vs unit-count discrepancy know which
    # tool carries the canonical unit totals (issue #105).
    #
    # @param metadata_store [Storage::MetadataStore::Interface] the resolved
    #   bundle's metadata store (M7)
    # @return [String, nil] Overview string, or nil if the store is empty
    # @raise [StoreError] the metadata store failed
    def build_structural_context(metadata_store)
      total = metadata_store.count
      return nil if total.zero?

      type_counts = STRUCTURAL_TYPES.filter_map do |type|
        count = metadata_store.find_by_type(type).size
        "#{count} #{type} entries" if count.positive?
      end

      "Codebase: #{total} searchable entries (#{type_counts.join(', ')}). " \
        'Entries include per-chunk rows for chunked units; see `structure` for canonical unit counts.'
    rescue StoreError
      raise
    rescue StandardError => e
      # MCP-6: this used to rescue to nil — the last swallow-to-empty on the
      # query path. A broken metadata store dropped the banner and every
      # answer looked like a healthy codebase with nothing to say about
      # itself. It is a metadata read like any other; raise the shared typed
      # store error so the MCP boundary can report degraded_index.
      raise StoreError.new(
        "metadata store failed while building the structural overview: #{e.class}: #{e.message}",
        store: :metadata
      )
    end
  end
end
