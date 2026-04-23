# frozen_string_literal: true

# Ruby 3.2 autoloads Set, but the gem supports >= 3.0 — make the require
# explicit so +filter_by_type+ works on the whole supported range.
require 'set'

require_relative 'retrieval/query_classifier'
require_relative 'retrieval/search_executor'
require_relative 'retrieval/ranker'
require_relative 'retrieval/context_assembler'

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
    # Diagnostic trace for retrieval quality analysis.
    RetrievalTrace = Struct.new(:classification, :strategy, :candidate_count,
                                :ranked_count, :tokens_used, :elapsed_ms,
                                keyword_init: true)

    # The result of a retrieval operation.
    RetrievalResult = Struct.new(:context, :sources, :classification, :strategy, :tokens_used, :budget, :trace,
                                 keyword_init: true)

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
        chars_per_token: chars_per_token
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
      ollama_patterns = /\A(nomic-embed|bge-|mxbai-embed|snowflake-arctic|all-minilm)/
      model.match?(ollama_patterns) ? 1.5 : Retrieval::ContextAssembler::DEFAULT_CHARS_PER_TOKEN
    end
    private :infer_chars_per_token

    # Unit types excluded from retrieval by default. +test_mapping+ units
    # make up ~33% of a typical index and lexically dominate semantic rank
    # for production queries ("stripe webhook" often surfaces
    # stripe_webhook_spec.rb above the actual controller). Callers can
    # override by passing +types:+ (include-only) or an explicit +exclude_types:+.
    DEFAULT_EXCLUDE_TYPES = %w[test_mapping].freeze

    # Execute the full retrieval pipeline for a natural language query.
    #
    # Pipeline: classify -> execute -> rank -> filter -> assemble -> format
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
      filtered = filter_by_type(ranked, types: types, exclude_types: exclude_types)
      assembled = assemble_context(filtered, classification, budget)

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

      trace = RetrievalTrace.new(
        classification: classification,
        strategy: execution_result.strategy,
        candidate_count: execution_result.candidates.size,
        ranked_count: filtered.size,
        tokens_used: assembled.tokens_used,
        elapsed_ms: elapsed_ms
      )

      build_result(assembled, classification, execution_result.strategy, budget, trace)
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
      # (which come in with metadata: {}) still get type-filtered.
      type_from_hash(@metadata_store.find(candidate.identifier)) || ''
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
    def build_result(assembled, classification, strategy, budget, trace = nil)
      context = @formatter ? @formatter.call(assembled.context) : assembled.context

      RetrievalResult.new(
        context: context,
        sources: assembled.sources,
        classification: classification,
        strategy: strategy,
        tokens_used: assembled.tokens_used,
        budget: budget,
        trace: trace
      )
    end

    # Build a structural context overview from the metadata store.
    #
    # Queries the metadata store for total unit count and counts per type,
    # producing a summary like "Codebase: 42 units (10 models, 5 controllers, ...)".
    #
    # @return [String, nil] Overview string, or nil if the store is empty or on error
    def build_structural_context
      total = @metadata_store.count
      return nil if total.zero?

      type_counts = STRUCTURAL_TYPES.filter_map do |type|
        count = @metadata_store.find_by_type(type).size
        "#{count} #{type}s" if count.positive?
      end

      "Codebase: #{total} units (#{type_counts.join(', ')})"
    rescue StandardError
      nil
    end
  end
end
