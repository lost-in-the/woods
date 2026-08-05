# frozen_string_literal: true

module Woods
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
      #
      # +matched_fields+ is populated only on the keyword path — the list of
      # metadata field names whose values matched a query keyword. It feeds
      # {Ranker#keyword_score} (0.25 per field, capped at 1.0). Defaults to
      # nil for every other source (vector/graph/direct), which scores 0.0.
      Candidate = Struct.new(:identifier, :score, :source, :metadata, :matched_fields, keyword_init: true)

      # The result of a search execution.
      ExecutionResult = Struct.new(:candidates, :strategy, :query, keyword_init: true)

      # Strategy mapping from (intent, scope) → strategy.
      #
      # Covers pinpoint overrides for locate/reference (:direct).
      # Trace and framework intents are handled before this map is consulted.
      STRATEGY_MAP = {
        %i[locate pinpoint] => :direct,
        %i[reference pinpoint] => :direct
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
      # @param type_filter [Array<String>, nil] When set, vector and hybrid
      #   strategies push this down into the vector store's metadata
      #   filter — used by {Retriever#retrieve} to rank-within-type when
      #   the unfiltered global top-K had no candidate of the requested type.
      #   This explicit caller filter is the ONLY source of vector type
      #   filters — the classifier's +target_type+ never becomes one (#184).
      # @param strategy [Symbol, nil] Override the classifier-selected strategy.
      #   {Retriever#within_type_fallback} passes +:vector+ here because the
      #   vector path is the only one that honors +type_filter+; if the
      #   classifier picked +:keyword+ / +:graph+ / +:direct+ the fallback
      #   would otherwise silently re-run the same strategy, get filtered to
      #   empty, and violate the "never empty when units exist" contract.
      # @return [ExecutionResult] Candidates with strategy metadata
      def execute(query:, classification:, limit: 20, type_filter: nil, strategy: nil)
        strategy ||= select_strategy(classification)
        candidates = run_strategy(
          strategy,
          query: query,
          classification: classification,
          limit: limit,
          type_filter: type_filter
        )

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

        # Intent-level overrides (apply regardless of scope)
        return :graph if intent == :trace
        return :keyword if intent == :framework

        # Pinpoint overrides for locate/reference
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
      # @param type_filter [Array<String>, nil] Pushed into vector filters
      # @return [Array<Candidate>]
      def run_strategy(strategy, query:, classification:, limit:, type_filter: nil)
        case strategy
        when :vector
          execute_vector(query, limit: limit, type_filter: type_filter)
        when :keyword
          execute_keyword(classification: classification, limit: limit)
        when :graph
          execute_graph(classification: classification, limit: limit)
        when :hybrid
          execute_hybrid(query, classification: classification, limit: limit, type_filter: type_filter)
        when :direct
          execute_direct(classification: classification, limit: limit)
        end
      end

      # Vector strategy: embed the query and search by similarity.
      #
      # Takes no classification — the vector path is filtered only by the
      # caller's explicit +type_filter+; see {#build_vector_filters} (#184).
      #
      # @return [Array<Candidate>]
      def execute_vector(query, limit:, type_filter: nil)
        query_vector = @embedding_provider.embed(query)
        filters = build_vector_filters(type_filter)

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
      # Alongside the best score, accumulates +matched_fields+ — the union
      # across keywords of the record fields that matched (see
      # {#matched_fields_for}).
      #
      # @param keywords [Array<String>]
      # @return [Hash<String, Hash>] id => { score:, metadata:, matched_fields: }
      def merge_keyword_results(keywords)
        results_by_id = {}
        keywords.each do |keyword|
          results = @metadata_store.search(keyword)
          results.each_with_index do |r, index|
            id = r['id']
            score = 1.0 - (index.to_f / [results.size, 10].max)
            merge_keyword_hit(results_by_id, id, score, r, matched_fields_for(r, keyword))
          end
        end
        results_by_id
      end

      # Fold a single keyword hit into the merged results: best score wins,
      # matched fields union across keywords.
      #
      # @param results_by_id [Hash<String, Hash>] Accumulator (mutated)
      # @param id [String] Candidate identifier
      # @param score [Float] Rank-derived score for this hit
      # @param record [Hash] The metadata record returned by the store
      # @param matched [Array<String>] Fields that matched this keyword
      # @return [void]
      def merge_keyword_hit(results_by_id, id, score, record, matched)
        entry = results_by_id[id]
        if entry.nil?
          results_by_id[id] = { score: score, metadata: record, matched_fields: matched }
        else
          entry[:score] = score if score > entry[:score]
          entry[:matched_fields] |= matched
        end
      end

      # Metadata record fields never counted as keyword matches: +id+
      # duplicates +identifier+ (the store injects it), and +updated_at+
      # is bookkeeping.
      KEYWORD_MATCH_SKIPPED_FIELDS = %w[id updated_at].freeze
      private_constant :KEYWORD_MATCH_SKIPPED_FIELDS
      # Approximate which fields of a metadata record matched a keyword.
      #
      # The metadata store's +search+ probes fields but does not report
      # which ones hit (SQLite runs a LIKE over the JSON blob; InMemory
      # scans serialized records) — so per-candidate matched fields are not
      # recoverable from the store without changing its interface. Instead,
      # the executor re-checks the returned record: every top-level field
      # whose stringified value contains the keyword (case-insensitively,
      # matching SQLite's ASCII LIKE semantics) counts as matched. This is
      # the input to {Ranker#keyword_score}'s 0.25-per-field table.
      #
      # @param record [Hash] Metadata record from the store (string keys)
      # @param keyword [String] The keyword that produced this record
      # @return [Array<String>] Names of fields whose values matched
      def matched_fields_for(record, keyword)
        return [] unless record.is_a?(Hash)

        needle = keyword.to_s.downcase
        return [] if needle.empty?

        record.filter_map do |field, value|
          next if KEYWORD_MATCH_SKIPPED_FIELDS.include?(field.to_s)

          field.to_s if value.to_s.downcase.include?(needle)
        end
      end

      # Rank merged keyword results into Candidate objects.
      #
      # @param results [Hash<String, Hash>]
      # @param limit [Integer]
      # @return [Array<Candidate>]
      def rank_keyword_results(results, limit)
        scored = results.map do |id, data|
          matched = data[:matched_fields]
          Candidate.new(identifier: id, score: data[:score], source: :keyword,
                        metadata: data[:metadata],
                        matched_fields: matched && !matched.empty? ? matched : nil)
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
      def execute_hybrid(query, classification:, limit:, type_filter: nil)
        # Gather from all three sources
        vector_candidates = execute_vector(query, limit: limit, type_filter: type_filter)
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

      # Build metadata filters for vector search from the caller's
      # explicit type filter.
      #
      # The classifier-derived +target_type+ is deliberately NOT pushed
      # down here (#184). It is a heuristic, and hard-filtering on it had
      # no fallback — a mainline query like "How do we get the current
      # user?" classified target :route and the vector search excluded
      # everything but route units. The heuristic still reaches the
      # {Ranker} as the soft +type_match+ signal, which boosts matching
      # types without excluding anything. A caller-supplied +type_filter+
      # keeps hard-filter semantics: the caller opted into specific types,
      # and {Retriever#retrieve} owns the within-type fallback for that path.
      #
      # @param type_filter [Array<String>, nil]
      # @return [Hash]
      def build_vector_filters(type_filter)
        return {} if type_filter.nil? || type_filter.empty?

        { type: type_filter.map(&:to_s) }
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
