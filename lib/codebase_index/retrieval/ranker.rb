# frozen_string_literal: true

module CodebaseIndex
  module Retrieval
    # Ranks search candidates using weighted signal scoring and diversity adjustment.
    #
    # Combines multiple ranking signals into a final score:
    # - Semantic similarity from vector search
    # - Keyword match quality
    # - Recency (git change frequency)
    # - Importance (PageRank / structural importance)
    # - Type match (bonus when result type matches query target_type)
    # - Diversity (penalty for too many results of same type/namespace)
    #
    # After initial scoring, applies Reciprocal Rank Fusion (RRF) when
    # candidates come from multiple retrieval sources.
    #
    # @example
    #   ranker = Ranker.new(metadata_store: store)
    #   ranked = ranker.rank(candidates, classification: classification)
    #
    class Ranker
      # Signal weights for ranking — sum to 1.0.
      WEIGHTS = {
        semantic: 0.40,
        keyword: 0.20,
        recency: 0.15,
        importance: 0.10,
        type_match: 0.10,
        diversity: 0.05
      }.freeze

      # RRF constant — balances rank position vs. absolute score.
      # Standard value from the original RRF paper (Cormack et al., 2009).
      RRF_K = 60

      # @param metadata_store [#find] Store that resolves identifiers to unit metadata
      def initialize(metadata_store:)
        @metadata_store = metadata_store
      end

      # Rank candidates by weighted signal scoring with diversity adjustment.
      #
      # @param candidates [Array<Candidate>] Search candidates from executor
      # @param classification [QueryClassifier::Classification] Query classification
      # @return [Array<Candidate>] Re-ranked candidates (best first)
      def rank(candidates, classification:)
        return [] if candidates.empty?

        # Apply RRF if candidates come from multiple sources
        candidates = apply_rrf(candidates) if multi_source?(candidates)

        scored = score_candidates(candidates, classification)
        sorted = sorted_by_weighted_score(scored)
        apply_diversity_penalty(sorted)

        sorted.map { |item| item[:candidate] }
      end

      private

      # Check if candidates come from multiple retrieval sources.
      #
      # @param candidates [Array<Candidate>]
      # @return [Boolean]
      def multi_source?(candidates)
        candidates.map(&:source).uniq.size > 1
      end

      # Apply Reciprocal Rank Fusion across sources.
      #
      # RRF formula: score(d) = sum(1/(k + rank_i(d)))
      # Each source's candidates are ranked independently, then RRF
      # merges ranks into a single score.
      #
      # @param candidates [Array<Candidate>]
      # @return [Array<Candidate>] Merged candidates with RRF scores
      def apply_rrf(candidates)
        rrf_scores, metadata_map = compute_rrf_scores(candidates)
        rebuild_rrf_candidates(candidates, rrf_scores, metadata_map)
      end

      # Compute RRF scores across all sources.
      #
      # @return [Array(Hash, Hash)] [rrf_scores, metadata_map]
      def compute_rrf_scores(candidates)
        rrf_scores = Hash.new(0.0)
        metadata_map = {}

        candidates.group_by(&:source).each_value do |source_candidates|
          ranked = source_candidates.sort_by { |c| -c.score }
          ranked.each_with_index do |candidate, rank|
            rrf_scores[candidate.identifier] += 1.0 / (RRF_K + rank)
            metadata_map[candidate.identifier] ||= candidate.metadata
          end
        end

        [rrf_scores, metadata_map]
      end

      # Rebuild candidates with merged RRF scores.
      #
      # @return [Array<Candidate>]
      def rebuild_rrf_candidates(candidates, rrf_scores, metadata_map)
        original_by_id = candidates.index_by(&:identifier)
        rrf_scores.sort_by { |_id, score| -score }.map do |identifier, score|
          original = original_by_id[identifier]
          build_candidate(
            identifier: identifier,
            score: score,
            source: original&.source || :rrf,
            metadata: metadata_map[identifier]
          )
        end
      end

      # Score each candidate across all signals.
      #
      # @param candidates [Array<Candidate>]
      # @param classification [QueryClassifier::Classification]
      # @return [Array<Hash>]
      def score_candidates(candidates, classification)
        # Batch-fetch all metadata in one query instead of per-candidate lookups
        unit_map = @metadata_store.find_batch(candidates.map(&:identifier))

        candidates.map do |candidate|
          unit = unit_map[candidate.identifier]

          {
            candidate: candidate,
            unit: unit, # cached to avoid double lookup in apply_diversity_penalty
            scores: {
              semantic: candidate.score.to_f,
              keyword: keyword_score(candidate),
              recency: recency_score(unit),
              importance: importance_score(unit),
              type_match: type_match_score(unit, classification),
              diversity: 1.0 # Adjusted after initial sort
            }
          }
        end
      end

      # Calculate weighted score for each item.
      #
      # @param scored [Array<Hash>]
      # @return [Array<Hash>] Sorted by weighted_score descending
      def sorted_by_weighted_score(scored)
        scored.each do |item|
          item[:weighted_score] = WEIGHTS.sum do |signal, weight|
            item[:scores][signal] * weight
          end
        end

        scored.sort_by { |item| -item[:weighted_score] }
      end

      # Keyword match score based on matched field count.
      #
      # @param candidate [Candidate]
      # @return [Float] 0.0 to 1.0
      def keyword_score(candidate)
        return 0.0 unless candidate.respond_to?(:matched_fields) && candidate.matched_fields

        [candidate.matched_fields.size * 0.25, 1.0].min
      end

      # Recency score based on git change frequency metadata.
      #
      # @param unit [Hash, nil] Unit metadata from store
      # @return [Float] 0.0 to 1.0
      def recency_score(unit)
        return 0.5 unless unit

        frequency = dig_metadata(unit, :git, :change_frequency)
        case frequency&.to_sym
        when :hot then 1.0
        when :active then 0.8
        when :dormant then 0.3
        when :new then 0.7
        else 0.5 # stable or unknown
        end
      end

      # Importance score based on PageRank / structural importance.
      #
      # @param unit [Hash, nil] Unit metadata from store
      # @return [Float] 0.0 to 1.0
      def importance_score(unit)
        return 0.5 unless unit

        importance = dig_metadata(unit, :importance)
        case importance&.to_s
        when 'high' then 1.0
        when 'medium' then 0.6
        when 'low' then 0.3
        else 0.5
        end
      end

      # Type match score — bonus when result type matches query target_type.
      #
      # @param unit [Hash, nil] Unit metadata from store
      # @param classification [QueryClassifier::Classification]
      # @return [Float] 0.0 to 1.0
      def type_match_score(unit, classification)
        return 0.5 unless unit
        return 0.5 unless classification.target_type

        unit_type = dig_metadata(unit, :type) || unit[:type]
        unit_type&.to_sym == classification.target_type ? 1.0 : 0.3
      end

      # Apply diversity penalty to avoid clustering by type/namespace.
      #
      # @param sorted [Array<Hash>] Scored items sorted by weighted_score
      # @return [void] Mutates items in place
      def apply_diversity_penalty(sorted)
        seen_namespaces = Hash.new(0)
        seen_types = Hash.new(0)

        sorted.each do |item|
          penalty = diversity_penalty_for(item, seen_namespaces, seen_types)
          next unless penalty

          item[:scores][:diversity] = 1.0 - penalty
          item[:weighted_score] -= penalty * WEIGHTS[:diversity]
        end

        sorted.sort_by! { |item| -item[:weighted_score] }
      end

      # Compute diversity penalty for a single item and update seen counts.
      #
      # Uses the unit cached in item[:unit] to avoid a redundant metadata store lookup.
      #
      # @return [Float, nil] Penalty amount, or nil if unit not found
      def diversity_penalty_for(item, seen_namespaces, seen_types)
        unit = item[:unit]
        return nil unless unit

        namespace = dig_metadata(unit, :namespace) || 'root'
        type = (dig_metadata(unit, :type) || 'unknown').to_s

        penalty = [(seen_namespaces[namespace] + seen_types[type]) * 0.1, 0.5].min
        seen_namespaces[namespace] += 1
        seen_types[type] += 1
        penalty
      end

      # Dig into unit metadata, handling both hash and object access.
      #
      # @param unit [Hash, Object] Unit data
      # @param keys [Array<Symbol>] Key path
      # @return [Object, nil]
      def dig_metadata(unit, *keys)
        if keys.size == 1
          unit.is_a?(Hash) ? (unit.dig(:metadata, keys[0]) || unit[keys[0]]) : nil
        else
          unit.is_a?(Hash) ? unit.dig(:metadata, *keys) : nil
        end
      end

      # Build a Candidate struct compatible with SearchExecutor::Candidate.
      #
      # @return [Candidate-like Struct]
      def build_candidate(identifier:, score:, source:, metadata:)
        SearchExecutor::Candidate.new(
          identifier: identifier,
          score: score,
          source: source,
          metadata: metadata
        )
      end
    end
  end
end
