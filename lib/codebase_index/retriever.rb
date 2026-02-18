# frozen_string_literal: true

require_relative 'retrieval/query_classifier'
require_relative 'retrieval/search_executor'
require_relative 'retrieval/ranker'
require_relative 'retrieval/context_assembler'

module CodebaseIndex
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
  #   retriever = CodebaseIndex::Retriever.new(
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
  class Retriever
    # Diagnostic trace for retrieval quality analysis.
    RetrievalTrace = Struct.new(:classification, :strategy, :candidate_count,
                                :ranked_count, :tokens_used, :elapsed_ms,
                                keyword_init: true)

    # The result of a retrieval operation.
    RetrievalResult = Struct.new(:context, :sources, :classification, :strategy, :tokens_used, :budget, :trace,
                                 keyword_init: true)

    # Unit types queried for the structural context overview.
    STRUCTURAL_TYPES = %w[model controller service job mailer component graphql].freeze

    # @param vector_store [Storage::VectorStore::Interface] Vector store adapter
    # @param metadata_store [Storage::MetadataStore::Interface] Metadata store adapter
    # @param graph_store [Storage::GraphStore::Interface] Graph store adapter
    # @param embedding_provider [Embedding::Provider::Interface] Embedding provider
    # @param formatter [#call, nil] Optional callable to post-process the context string
    def initialize(vector_store:, metadata_store:, graph_store:, embedding_provider:, formatter: nil)
      @metadata_store = metadata_store
      @formatter = formatter

      @classifier = Retrieval::QueryClassifier.new
      @executor = Retrieval::SearchExecutor.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        graph_store: graph_store,
        embedding_provider: embedding_provider
      )
      @ranker = Retrieval::Ranker.new(metadata_store: metadata_store)
      @assembler = Retrieval::ContextAssembler.new(metadata_store: metadata_store)
    end

    # Execute the full retrieval pipeline for a natural language query.
    #
    # Pipeline: classify -> execute -> rank -> assemble -> format
    #
    # @param query [String] Natural language query
    # @param budget [Integer] Token budget for context assembly
    # @return [RetrievalResult] Complete retrieval result
    def retrieve(query, budget: 8000)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      classification = @classifier.classify(query)
      execution_result = @executor.execute(query: query, classification: classification)
      ranked = @ranker.rank(execution_result.candidates, classification: classification)
      assembled = assemble_context(ranked, classification, budget)

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

      trace = RetrievalTrace.new(
        classification: classification,
        strategy: execution_result.strategy,
        candidate_count: execution_result.candidates.size,
        ranked_count: ranked.size,
        tokens_used: assembled.tokens_used,
        elapsed_ms: elapsed_ms
      )

      build_result(assembled, classification, execution_result.strategy, budget, trace)
    end

    private

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
        count = count_by_type(type)
        "#{count} #{type}s" if count.positive?
      end

      "Codebase: #{total} units (#{type_counts.join(', ')})"
    rescue StandardError
      nil
    end

    # Count units of a given type in the metadata store.
    #
    # @param type [String] The unit type to count
    # @return [Integer] Number of units of this type
    def count_by_type(type)
      @metadata_store.find_by_type(type).size
    end
  end
end
