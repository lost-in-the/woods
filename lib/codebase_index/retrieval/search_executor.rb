# frozen_string_literal: true

module CodebaseIndex
  module Retrieval
    # SearchExecutor maps a query classification to a retrieval strategy and
    # executes it against the configured stores.
    #
    # Strategies:
    # - :vector     — semantic similarity search (understand, implement, debug)
    # - :keyword    — exact identifier/text matching (locate, reference)
    # - :graph      — dependency traversal (trace)
    # - :hybrid     — vector + keyword + graph expansion (exploratory/comprehensive)
    # - :direct     — direct metadata lookup (pinpoint + locate/reference)
    #
    # @example
    #   executor = SearchExecutor.new(
    #     vector_store: vector_store,
    #     metadata_store: metadata_store,
    #     graph_store: graph_store,
    #     embedding_provider: embedding_provider
    #   )
    #   classification = QueryClassifier.new.classify("How does User model work?")
    #   result = executor.execute(query: "How does User model work?", classification: classification)
    #   result.candidates # => [Candidate, ...]
    #   result.strategy   # => :hybrid
    #
    class SearchExecutor
      # A single search candidate with provenance tracking.
      Candidate = Struct.new(:identifier, :score, :source, :metadata, keyword_init: true)

      # The result of a search execution.
      ExecutionResult = Struct.new(:candidates, :strategy, :query, keyword_init: true)

      # Strategy mapping from (intent, scope) → strategy.
      #
      # Pinpoint scope always uses :direct for locate/reference.
      # Comprehensive/exploratory scopes use :hybrid.
      # Framework intent always uses :keyword against framework sources.
      STRATEGY_MAP = {
        # [intent, scope] => strategy
        # Pinpoint
        %i[locate pinpoint] => :direct,
        %i[reference pinpoint] => :direct,

        # Trace always uses graph
        %i[trace pinpoint] => :graph,
        %i[trace focused] => :graph,
        %i[trace exploratory] => :graph,
        %i[trace comprehensive] => :graph,

        # Framework always keyword
        %i[framework pinpoint] => :keyword,
        %i[framework focused] => :keyword,
        %i[framework exploratory] => :keyword,
        %i[framework comprehensive] => :keyword
      }.freeze

      # @param vector_store [Storage::VectorStore::Interface] Vector store adapter
      # @param metadata_store [Storage::MetadataStore::Interface] Metadata store adapter
      # @param graph_store [Storage::GraphStore::Interface] Graph store adapter
      # @param embedding_provider [Embedding::Provider::Interface] Embedding provider
      def initialize(vector_store:, metadata_store:, graph_store:, embedding_provider:)
        @vector_store = vector_store
        @metadata_store = metadata_store
        @graph_store = graph_store
        @embedding_provider = embedding_provider
      end

      # Execute a search based on query classification.
      #
      # @param query [String] The original query text
      # @param classification [QueryClassifier::Classification] Classified query
      # @param limit [Integer] Maximum candidates to return
      # @return [ExecutionResult] Candidates with strategy metadata
      def execute(query:, classification:, limit: 20)
        strategy = select_strategy(classification)
        candidates = run_strategy(strategy, query: query, classification: classification, limit: limit)

        ExecutionResult.new(
          candidates: candidates.first(limit),
          strategy: strategy,
          query: query
        )
      end

      private

      # Select the best retrieval strategy for a classification.
      #
      # @param classification [QueryClassifier::Classification]
      # @return [Symbol] One of :vector, :keyword, :graph, :hybrid, :direct
      def select_strategy(classification)
        intent = classification.intent
        scope = classification.scope

        # Check explicit mapping first
        mapped = STRATEGY_MAP[[intent, scope]]
        return mapped if mapped

        # Comprehensive and exploratory scopes default to hybrid
        return :hybrid if %i[comprehensive exploratory].include?(scope)

        # Scope-based defaults for remaining intents
        case intent
        when :locate, :reference
          :keyword
        else
          :vector
        end
      end

      # Execute the selected strategy.
      #
      # @param strategy [Symbol] Strategy to execute
      # @param query [String] Original query text
      # @param classification [QueryClassifier::Classification]
      # @param limit [Integer] Max results
      # @return [Array<Candidate>]
      def run_strategy(strategy, query:, classification:, limit:)
        case strategy
        when :vector
          execute_vector(query, classification: classification, limit: limit)
        when :keyword
          execute_keyword(classification: classification, limit: limit)
        when :graph
          execute_graph(classification: classification, limit: limit)
        when :hybrid
          execute_hybrid(query, classification: classification, limit: limit)
        when :direct
          execute_direct(classification: classification, limit: limit)
        end
      end

      # Vector strategy: embed the query and search by similarity.
      #
      # @return [Array<Candidate>]
      def execute_vector(query, classification:, limit:)
        query_vector = @embedding_provider.embed(query)
        filters = build_vector_filters(classification)

        results = @vector_store.search(query_vector, limit: limit, filters: filters)
        results.map do |r|
          Candidate.new(identifier: r.id, score: r.score, source: :vector, metadata: r.metadata)
        end
      end

      # Keyword strategy: search metadata store by extracted keywords.
      #
      # Searches each keyword individually and merges results, keeping the
      # best score per identifier.
      #
      # @return [Array<Candidate>]
      def execute_keyword(classification:, limit:)
        keywords = classification.keywords
        return [] if keywords.empty?

        all_results = merge_keyword_results(keywords)
        rank_keyword_results(all_results, limit)
      end

      # Search each keyword individually and merge, keeping best score per ID.
      #
      # @param keywords [Array<String>]
      # @return [Hash<String, Hash>] id => { score:, metadata: }
      def merge_keyword_results(keywords)
        results_by_id = {}
        keywords.each do |keyword|
          results = @metadata_store.search(keyword)
          results.each_with_index do |r, index|
            id = r['id']
            score = 1.0 - (index.to_f / [results.size, 10].max)
            results_by_id[id] = { score: score, metadata: r } if !results_by_id[id] || score > results_by_id[id][:score]
          end
        end
        results_by_id
      end

      # Rank merged keyword results into Candidate objects.
      #
      # @param results [Hash<String, Hash>]
      # @param limit [Integer]
      # @return [Array<Candidate>]
      def rank_keyword_results(results, limit)
        scored = results.map do |id, data|
          Candidate.new(identifier: id, score: data[:score], source: :keyword, metadata: data[:metadata])
        end
        scored.sort_by { |c| -c.score }.first(limit)
      end

      # Graph strategy: find related units via dependency traversal.
      #
      # @return [Array<Candidate>]
      def execute_graph(classification:, limit:)
        candidates = []

        # First, use keywords to find seed identifiers in the metadata store
        seeds = find_seed_identifiers(classification)
        return [] if seeds.empty?

        seeds.each do |seed_id|
          # Forward dependencies
          deps = @graph_store.dependencies_of(seed_id)
          deps.each do |dep|
            candidates << Candidate.new(identifier: dep, score: 0.8, source: :graph, metadata: {})
          end

          # Reverse dependencies (dependents)
          dependents = @graph_store.dependents_of(seed_id)
          dependents.each do |dep|
            candidates << Candidate.new(identifier: dep, score: 0.7, source: :graph, metadata: {})
          end

          # The seed itself
          candidates << Candidate.new(identifier: seed_id, score: 1.0, source: :graph, metadata: {})
        end

        deduplicate(candidates).first(limit)
      end

      # Hybrid strategy: combine vector, keyword, and graph expansion.
      #
      # @return [Array<Candidate>]
      def execute_hybrid(query, classification:, limit:)
        # Gather from all three sources
        vector_candidates = execute_vector(query, classification: classification, limit: limit)
        keyword_candidates = execute_keyword(classification: classification, limit: limit)

        # Graph expansion on top vector results
        graph_candidates = []
        vector_candidates.first(3).each do |candidate|
          deps = @graph_store.dependencies_of(candidate.identifier)
          deps.each do |dep|
            graph_candidates << Candidate.new(
              identifier: dep, score: 0.5, source: :graph_expansion, metadata: {}
            )
          end
        end

        all = vector_candidates + keyword_candidates + graph_candidates
        deduplicate(all).first(limit)
      end

      # Direct strategy: look up specific identifiers from keywords.
      #
      # Tries each keyword as-is and capitalized (e.g. "user" → "User")
      # since keywords are lowercased but identifiers are typically PascalCase.
      #
      # @return [Array<Candidate>]
      def execute_direct(classification:, limit:)
        keywords = classification.keywords
        return [] if keywords.empty?

        candidates = lookup_keyword_variants(keywords)

        # Fall back to keyword search if direct lookups miss
        return execute_keyword(classification: classification, limit: limit) if candidates.empty?

        candidates.first(limit)
      end

      # Try each keyword as-is and in capitalized forms against the metadata store.
      #
      # @param keywords [Array<String>]
      # @return [Array<Candidate>]
      def lookup_keyword_variants(keywords)
        candidates = []
        keywords.each do |keyword|
          variants = [keyword, keyword.capitalize, keyword.split('_').map(&:capitalize).join].uniq
          variants.each do |variant|
            result = @metadata_store.find(variant)
            next unless result

            candidates << Candidate.new(identifier: variant, score: 1.0, source: :direct, metadata: result)
            break
          end
        end
        candidates
      end

      # Build metadata filters for vector search based on classification.
      #
      # @param classification [QueryClassifier::Classification]
      # @return [Hash]
      def build_vector_filters(classification)
        filters = {}
        filters[:type] = classification.target_type.to_s if classification.target_type
        filters
      end

      # Find seed identifiers from classification keywords via metadata search.
      #
      # @param classification [QueryClassifier::Classification]
      # @return [Array<String>]
      def find_seed_identifiers(classification)
        seeds = []

        # Try direct lookups for capitalized keywords (likely class names)
        classification.keywords.each do |keyword|
          capitalized = keyword.split('_').map(&:capitalize).join
          result = @metadata_store.find(capitalized)
          seeds << capitalized if result
        end

        # Fall back to search if no direct hits
        if seeds.empty? && classification.keywords.any?
          results = @metadata_store.search(classification.keywords.join(' '))
          seeds = results.first(3).map { |r| r['id'] }
        end

        seeds
      end

      # Deduplicate candidates, keeping the highest-scored entry per identifier.
      #
      # @param candidates [Array<Candidate>]
      # @return [Array<Candidate>]
      def deduplicate(candidates)
        best = {}
        candidates.each do |c|
          existing = best[c.identifier]
          best[c.identifier] = c if existing.nil? || c.score > existing.score
        end
        best.values.sort_by { |c| -c.score }
      end
    end
  end
end
