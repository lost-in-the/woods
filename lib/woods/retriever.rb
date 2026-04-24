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
    RetrievalTrace = Struct.new(:classification, :strategy, :candidate_count,
                                :ranked_count, :tokens_used, :elapsed_ms,
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

    # Unit types queried for the structural context overview.
    STRUCTURAL_TYPES = %w[model controller service job mailer component graphql].freeze

    # Direct handles to the injected stores. The sub-components
    # ({Retrieval::SearchExecutor}, {Retrieval::Ranker},
    # {Retrieval::ContextAssembler}) hold their own references too, but those
    # are implementation details — callers that want to mutate store contents
    # (e.g. the MCP +reload+ tool) read through these accessors. All three
    # refer to the same Ruby objects the sub-components were initialised with,
    # so in-place +#clear!+ + +#bulk_load+ propagates through the entire
    # pipeline without re-instantiating sub-components.
    attr_reader :vector_store, :metadata_store, :graph_store

    # @param vector_store [Storage::VectorStore::Interface] Vector store adapter
    # @param metadata_store [Storage::MetadataStore::Interface] Metadata store adapter
    # @param graph_store [Storage::GraphStore::Interface] Graph store adapter
    # @param embedding_provider [Embedding::Provider::Interface] Embedding provider
    # @param formatter [#call, nil] Optional callable to post-process the context string
    def initialize(vector_store:, metadata_store:, graph_store:, embedding_provider:, formatter: nil)
      @vector_store = vector_store
      @metadata_store = metadata_store
      @graph_store = graph_store
      @formatter = formatter

      @classifier = Retrieval::QueryClassifier.new
      @executor = Retrieval::SearchExecutor.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        graph_store: graph_store,
        embedding_provider: embedding_provider
      )
      @ranker = Retrieval::Ranker.new(metadata_store: metadata_store, graph_store: graph_store)
      # Match truncation sizing to the embedding provider's tokenizer so
      # Ollama-indexed corpora (ratio ~1.5) don't get over-truncated by
      # an OpenAI-sized default (4.0). Unknown/missing providers fall
      # back to the OpenAI-friendly default.
      chars_per_token = infer_chars_per_token(embedding_provider)
      @assembler = Retrieval::ContextAssembler.new(
        metadata_store: metadata_store,
        chars_per_token: chars_per_token,
        token_counter: infer_token_counter(embedding_provider)
      )
    end

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
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      classification = @classifier.classify(query)
      execution_result = @executor.execute(query: query, classification: classification)
      ranked = @ranker.rank(execution_result.candidates, classification: classification)

      type_list = normalize_type_list(types)
      filtered, fallback_ran = apply_type_filter(
        ranked, query, classification, types: types, type_list: type_list, exclude_types: exclude_types
      )
      type_rank_context = type_list ? build_type_rank_context(ranked, type_list, fallback_ran: fallback_ran) : nil

      assembled = assemble_context(filtered, classification, budget)
      trace = build_trace(classification, execution_result, filtered, assembled, start_time)

      build_result(
        assembled: assembled, classification: classification, strategy: execution_result.strategy,
        budget: budget, trace: trace, type_rank_context: type_rank_context
      )
    end

    private

    # Filter ranked candidates by type, using an include-list when +types+
    # is set and an exclude-list otherwise (default: +DEFAULT_EXCLUDE_TYPES+,
    # extended by any +exclude_types+ the caller adds).
    #
    # Candidate type comes from either the metadata store (when populated)
    # or the candidate's inline +metadata+ hash — both are probed so the
    # filter still works on graph-expansion candidates that carry no
    # vector-store metadata.
    #
    # @param candidates [Array<Candidate>]
    # @param types [Array<String, Symbol>, nil]
    # @param exclude_types [Array<String, Symbol>, nil]
    # @return [Array<Candidate>]
    def filter_by_type(candidates, types:, exclude_types:)
      allowed = normalize_type_list(types)
      return candidates.select { |c| allowed.include?(candidate_type(c)) } if allowed

      excluded = (normalize_type_list(exclude_types) || Set.new) | DEFAULT_EXCLUDE_TYPES.to_set
      return candidates if excluded.empty?

      candidates.reject { |c| excluded.include?(candidate_type(c)) }
    end

    def normalize_type_list(list)
      return nil if list.nil? || list.empty?

      list.to_set(&:to_s)
    end

    def candidate_type(candidate)
      inline = type_from_hash(candidate.metadata)
      return inline if inline

      # Fall back to the metadata store lookup so graph-expansion candidates
      # (which come in with metadata: {}) still get type-filtered. Strip the
      # chunk suffix first: chunked vector hits arrive with +Foo#chunk_0+
      # but the store is keyed by the base identifier +Foo+ only, and a
      # missed lookup would let the candidate past the default-exclude
      # (type resolves to '', which +excluded+ never contains).
      lookup_id = candidate.identifier.to_s.sub(CHUNK_SUFFIX_PATTERN, '')
      type_from_hash(@metadata_store.find(lookup_id)) || ''
    rescue StandardError
      ''
    end

    def type_from_hash(hash)
      return nil unless hash

      value = hash[:type] || hash['type']
      value&.to_s
    end

    # Assemble token-budgeted context from ranked candidates.
    #
    # @param ranked [Array<Candidate>] Ranked search candidates
    # @param classification [QueryClassifier::Classification] Query classification
    # @return [AssembledContext]
    def assemble_context(ranked, classification, budget)
      @assembler.assemble(
        candidates: ranked,
        classification: classification,
        structural_context: build_structural_context,
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
    def apply_type_filter(ranked, query, classification, types:, type_list:, exclude_types:)
      filtered = filter_by_type(ranked, types: types, exclude_types: exclude_types)
      return [filtered, false] unless type_list && filtered.empty?

      [within_type_fallback(query, classification, type_list, exclude_types), true]
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
    def within_type_fallback(query, classification, type_list, exclude_types)
      type_array = type_list.to_a
      return [] if type_array.all? { |t| total_of_type(t).to_i.zero? }

      fallback = @executor.execute(
        query: query, classification: classification,
        type_filter: type_array, strategy: :vector
      )
      ranked = @ranker.rank(fallback.candidates, classification: classification)
      filter_by_type(ranked, types: type_array, exclude_types: exclude_types)
    end

    def build_trace(classification, execution_result, filtered, assembled, start_time)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)
      RetrievalTrace.new(
        classification: classification,
        strategy: execution_result.strategy,
        candidate_count: execution_result.candidates.size,
        ranked_count: filtered.size,
        tokens_used: assembled.tokens_used,
        elapsed_ms: elapsed_ms
      )
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
    # @param type_list [Set<String>]
    # @param fallback_ran [Boolean] Whether rank-within-type fallback ran
    # @return [Hash{String => Hash}]
    def build_type_rank_context(ranked, type_list, fallback_ran:)
      global_k = ranked.size
      type_list.to_h do |type|
        match_index = ranked.index { |c| candidate_type(c) == type }
        top_rank = match_index ? match_index + 1 : nil
        total = total_of_type(type)
        [
          type,
          {
            source: type_source(top_rank, total, fallback_ran: fallback_ran),
            top_of_type_global_rank: top_rank,
            global_k: global_k,
            total_of_type: total
          }
        ]
      end
    end

    # Pick the :source enum value for a single type based on where its
    # candidate ended up. See RetrievalResult's docstring for the enum.
    def type_source(top_rank, total, fallback_ran:)
      return :in_top_k if top_rank
      return :absent if total.to_i.zero?
      return :within_type_fallback if fallback_ran

      :outside_top_k
    end

    def total_of_type(type)
      @metadata_store.find_by_type(type).size
    rescue StandardError
      nil
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
    # @return [String, nil] Overview string, or nil if the store is empty or on error
    def build_structural_context
      total = @metadata_store.count
      return nil if total.zero?

      type_counts = STRUCTURAL_TYPES.filter_map do |type|
        count = @metadata_store.find_by_type(type).size
        "#{count} #{type}s" if count.positive?
      end

      "Codebase: #{total} searchable entries (#{type_counts.join(', ')}). " \
        'Entries include per-chunk rows for chunked units; run `structure` for canonical unit counts.'
    rescue StandardError
      nil
    end
  end
end
