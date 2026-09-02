# frozen_string_literal: true

module Woods
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

      # Chunked units embed as `Identifier#chunk_N`; metadata and the graph are
      # keyed on the bare identifier. Mirrors the same constant in Retriever,
      # Bootstrapper, ContextAssembler and Indexer — kept local to each, as
      # they are, rather than introducing a shared home in a patch release.
      CHUNK_SUFFIX_PATTERN = /#chunk_\d+\z/
      private_constant :CHUNK_SUFFIX_PATTERN

      # RRF constant — balances rank position vs. absolute score.
      # Standard value from the original RRF paper (Cormack et al., 2009).
      RRF_K = 60

      # @param metadata_store [#find] Store that resolves identifiers to unit metadata
      # @param graph_store [#pagerank, nil] Optional graph store exposing PageRank scores.
      #   When present, PageRank rank-percentile replaces the bucketed importance signal.
      def initialize(metadata_store:, graph_store: nil)
        @metadata_store = metadata_store
        @graph_store = graph_store
      end

      # Rank candidates by weighted signal scoring with diversity adjustment.
      #
      # Returned candidates carry their final weighted score (0.0–1.0) in
      # +score+ — NOT the raw retrieval score they arrived with. Downstream
      # consumers ({ContextAssembler#assemble_section} re-sorts by +score+;
      # source attributions report it) must agree with the ranked order, so
      # the ranker rewrites the score the same way {#apply_rrf} always has.
      #
      # @param candidates [Array<Candidate>] Search candidates from executor
      # @param classification [QueryClassifier::Classification] Query classification
      # @return [Array<Candidate>] Re-ranked candidates (best first), scores
      #   rewritten to the final weighted score
      def rank(candidates, classification:)
        return [] if candidates.empty?

        # Apply RRF if candidates come from multiple sources
        candidates = apply_rrf(candidates) if multi_source?(candidates)

        scored = score_candidates(candidates, classification)
        sorted = sorted_by_weighted_score(scored)
        apply_diversity_penalty(sorted)

        finalize_ranked(sorted)
      end

      # Drop the memoized PageRank rank-percentile map so the next {#rank}
      # call recomputes it from the graph store.
      #
      # The map is memoized per Ranker instance ({#pagerank_importance_map}),
      # so a Ranker outlives any change to the graph it was built against.
      # The Index MCP reload path does NOT call this: the M7 build-then-swap
      # transaction ({Woods::MCP::Bootstrapper.commit_reload!}) installs a
      # whole fresh Pipeline — including a fresh Ranker with no memo — rather
      # than mutating a live graph in place, and must keep doing so.
      #
      # This is therefore an API for direct embedders only: code that holds a
      # Ranker itself and repoints its graph store without rebuilding the
      # Ranker has to invalidate the memo here, or the ranker keeps scoring
      # importance from the retired graph.
      #
      # @return [void]
      def invalidate_pagerank_cache!
        @pagerank_importance_map = nil
      end

      private

      # Rebuild each ranked candidate with its final weighted score.
      #
      # Mirrors {#rebuild_rrf_candidates}: a fresh Candidate is built rather
      # than mutating the executor's structs in place, so callers holding
      # the pre-rank candidate list (e.g. RetrievalTrace consumers) keep
      # their original scores.
      #
      # @param sorted [Array<Hash>] Scored items sorted by weighted_score
      # @return [Array<Candidate>]
      def finalize_ranked(sorted)
        sorted.map do |item|
          candidate = item[:candidate]
          build_candidate(
            identifier: candidate.identifier,
            score: item[:weighted_score],
            source: candidate.source,
            metadata: candidate.metadata,
            matched_fields: candidate.matched_fields
          )
        end
      end

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
      # Raw RRF values live on a tiny scale (~1/(k+1) ≈ 0.016 per source),
      # while every other ranking signal is 0.0–1.0 — feeding them straight
      # into the weighted sum as +semantic+ made the 0.40 weight contribute
      # at most ~0.02 and let recency/importance spreads dominate any fused
      # query. Min-max normalizing across the merged list restores the
      # 0.0–1.0 scale (see {#normalize_scores}); the single-source path is
      # untouched because provider similarity scores already arrive 0–1.
      #
      # @param candidates [Array<Candidate>]
      # @return [Array<Candidate>] Merged candidates with normalized RRF scores
      def apply_rrf(candidates)
        rrf_scores, metadata_map, matched_fields_map = compute_rrf_scores(candidates)
        rebuild_rrf_candidates(candidates, normalize_scores(rrf_scores), metadata_map, matched_fields_map)
      end

      # Compute RRF scores across all sources.
      #
      # Keyed on the chunk-stripped BASE identifier ({#base_identifier}),
      # not the raw candidate identifier: a chunked unit's vector hit
      # arrives as `Identifier#chunk_N` while its keyword hit arrives as
      # the bare `Identifier` — keying on the raw id treated those as two
      # unrelated identifiers and they never fused, so chunked corpora
      # (rails_source-heavy hosts) got zero RRF benefit from hybrid search.
      #
      # Also accumulates per-identifier metadata (first non-empty wins) and
      # matched fields (union across sources) so the merged candidate keeps
      # the keyword signal — dropping +matched_fields+ here would kill
      # {#keyword_score} on exactly the multi-source (hybrid) path where
      # keyword evidence matters most.
      #
      # @return [Array(Hash, Hash, Hash)] [rrf_scores, metadata_map, matched_fields_map]
      def compute_rrf_scores(candidates)
        rrf_scores = Hash.new(0.0)
        metadata_map = {}
        matched_fields_map = {}

        candidates.group_by(&:source).each_value do |source_candidates|
          ranked = source_candidates.sort_by { |c| -c.score }
          ranked.each_with_index do |candidate, idx|
            base_id = base_identifier(candidate.identifier)
            # RRF is 1-based (Cormack et al., 2009): top-ranked doc uses rank 1, not 0.
            rrf_scores[base_id] += 1.0 / (RRF_K + idx + 1)
            # `||=` alone is wrong here: a graph-expansion candidate's `{}`
            # is truthy, so it would permanently shadow a real metadata hash
            # arriving from a later-processed source. Only lock in a value
            # once it's actually non-empty.
            existing = metadata_map[base_id]
            metadata_map[base_id] = candidate.metadata if existing.nil? || existing.empty?
            merge_matched_fields(matched_fields_map, base_id, candidate)
          end
        end

        [rrf_scores, metadata_map, matched_fields_map]
      end

      # Union a candidate's matched fields into the per-identifier map.
      #
      # @param matched_fields_map [Hash{String => Array<String>}] Accumulator (mutated)
      # @param identifier [String] Chunk-stripped base identifier to accumulate under
      # @param candidate [Candidate]
      # @return [void]
      def merge_matched_fields(matched_fields_map, identifier, candidate)
        fields = candidate.respond_to?(:matched_fields) ? candidate.matched_fields : nil
        return unless fields

        matched_fields_map[identifier] = (matched_fields_map[identifier] || []) | fields
      end

      # Min-max normalize a score map to the 0.0–1.0 range.
      #
      # The degenerate all-equal case (including a single candidate) maps
      # everything to 1.0 — an identifier every source agreed on is a full-
      # strength semantic match, not a zero.
      #
      # @param scores [Hash{String => Float}]
      # @return [Hash{String => Float}]
      def normalize_scores(scores)
        min, max = scores.values.minmax
        spread = max - min
        return scores.transform_values { 1.0 } if spread.zero?

        scores.transform_values { |score| (score - min) / spread }
      end

      # Rebuild candidates with merged (normalized) RRF scores.
      #
      # +identifier+ in +rrf_scores+ is already the chunk-stripped base
      # identifier (see {#compute_rrf_scores}) — the merged Candidate is
      # built under that base id, which is also what {#score_candidates}
      # looks metadata up by, so a fused chunk/base pair scores and
      # displays as the single unit it represents.
      #
      # @return [Array<Candidate>]
      def rebuild_rrf_candidates(candidates, rrf_scores, metadata_map, matched_fields_map)
        original_by_id = pick_merged_source(candidates)
        rrf_scores.sort_by { |_id, score| -score }.map do |identifier, score|
          original = original_by_id[identifier]
          build_candidate(
            identifier: identifier,
            score: score,
            source: original&.source || :rrf,
            metadata: metadata_map[identifier],
            matched_fields: matched_fields_map[identifier]
          )
        end
      end

      # Pick the representative candidate (for +source+ attribution) per
      # base identifier across every source that hit it.
      #
      # +:graph_expansion+ never wins this pick over a vector/keyword/direct
      # duplicate: a unit strongly hit by vector search AND reached via
      # graph expansion is a real primary result, not incidental context,
      # and {ContextAssembler#add_result_sections} routes solely on
      # +candidate.source+ to decide primary vs. supporting placement.
      # Plain last-wins (the prior behavior, matching ActiveSupport's
      # +Enumerable#index_by+) let whichever duplicate the source-grouping
      # loop visited last silently demote it. Within a precedence tier,
      # last-wins is preserved.
      #
      # @param candidates [Array<Candidate>]
      # @return [Hash{String => Candidate}]
      def pick_merged_source(candidates)
        original_by_id = {}
        candidates.each do |c|
          id = base_identifier(c.identifier)
          existing = original_by_id[id]
          next if existing && existing.source != :graph_expansion && c.source == :graph_expansion

          original_by_id[id] = c
        end
        original_by_id
      end

      # Score each candidate across all signals.
      #
      # @param candidates [Array<Candidate>]
      # @param classification [QueryClassifier::Classification]
      # @return [Array<Hash>]
      def score_candidates(candidates, classification)
        # Look up by *base* identifier. A chunked unit's vector ids carry a
        # `#chunk_N` suffix, but the metadata store and the PageRank map are
        # both keyed on the unit — so passing the raw identifier missed every
        # chunk, and recency, importance, type_match and diversity all fell
        # back to their neutral values precisely on chunked corpora
        # (rails_source-heavy hosts), leaving semantic+keyword to decide alone.
        # The bootstrapper and the assembler already strip; the ranker was the
        # one consumer that did neither.
        base_ids = candidates.to_h { |candidate| [candidate.identifier, base_identifier(candidate.identifier)] }
        unit_map = @metadata_store.find_batch(base_ids.values.uniq)

        candidates.map do |candidate|
          base_id = base_ids[candidate.identifier]
          unit = unit_map[base_id]

          {
            candidate: candidate,
            unit: unit, # cached to avoid double lookup in apply_diversity_penalty
            scores: {
              semantic: candidate.score.to_f,
              keyword: keyword_score(candidate),
              recency: recency_score(unit),
              importance: importance_score(unit, base_id),
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

      # The unit identifier behind a possibly chunk-suffixed candidate id.
      #
      # @param identifier [String]
      # @return [String]
      def base_identifier(identifier)
        identifier.to_s.sub(CHUNK_SUFFIX_PATTERN, '')
      end

      # Importance score based on PageRank / structural importance.
      #
      # Prefers live PageRank from the graph store (rank-percentile 0.0–1.0) when
      # available. Falls back to bucketed importance metadata (`:high`/`:medium`/`:low`)
      # when there is no graph store, the PageRank map is empty, or the identifier
      # is not yet indexed (e.g., a new unit since the last extraction).
      #
      # @param unit [Hash, nil] Unit metadata from store
      # @param identifier [String] Candidate identifier (matched against PageRank keys)
      # @return [Float] 0.0 to 1.0
      def importance_score(unit, identifier)
        pagerank = pagerank_importance_map[identifier]
        return pagerank if pagerank

        return 0.5 unless unit

        importance = dig_metadata(unit, :importance)
        case importance&.to_s
        when 'high' then 1.0
        when 'medium' then 0.6
        when 'low' then 0.3
        else 0.5
        end
      end

      # Lazily-computed rank-percentile map derived from the graph store's PageRank.
      #
      # Top-ranked identifier gets 1.0, bottom-ranked gets 1/n. Identifiers absent
      # from PageRank (new units, ephemeral candidates) return nil and fall back
      # to the bucketed importance signal.
      #
      # @return [Hash{String => Float}]
      def pagerank_importance_map
        @pagerank_importance_map ||= compute_pagerank_importance_map
      end

      # Compute rank-percentile scores from the graph store's PageRank hash.
      #
      # `respond_to?` alone is the wrong guard: {Storage::GraphStore::Interface}
      # *defines* +#pagerank+ as a +NotImplementedError+ stub, so an adapter
      # that merely includes the interface without overriding it still
      # answers +respond_to?+ with +true+ (B-108) — and +NotImplementedError+
      # is a +ScriptError+, which the rescue below does not catch on its own.
      #
      # @return [Hash{String => Float}] Empty hash when no graph store or no scores.
      def compute_pagerank_importance_map
        return {} unless @graph_store.respond_to?(:pagerank)

        scores = @graph_store.pagerank
        return {} if scores.nil? || scores.empty?

        ranked = scores.sort_by { |_id, score| -score }
        total = ranked.size.to_f
        ranked.each_with_index.to_h do |(identifier, _score), rank|
          [identifier, 1.0 - (rank / total)]
        end
      rescue StandardError, NotImplementedError
        {}
      end

      # Type match score — bonus when result type matches query target_type.
      #
      # @param unit [Hash, nil] Unit metadata from store
      # @param classification [QueryClassifier::Classification]
      # @return [Float] 0.0 to 1.0
      def type_match_score(unit, classification)
        return 0.5 unless unit
        return 0.5 unless classification.target_type

        unit_type = dig_metadata(unit, :type)
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

      # Dig a value out of a unit's metadata, tolerating both symbol and
      # string keys at every level.
      #
      # Units come from the metadata store, which returns STRING keys on
      # every real backend (SQLite round-trips through JSON.parse;
      # InMemory#store calls stringify_keys). The previous implementation
      # probed only symbol keys, so recency/importance/type_match/diversity
      # silently scored every unit at their neutral fallback in production —
      # the specs passed only because they stub symbol-keyed units.
      #
      # Looks under the `metadata` wrapper first, then falls back to a
      # top-level field for single-key lookups (namespace/type live on the
      # unit itself, not under metadata).
      #
      # @param unit [Hash, Object] Unit data
      # @param keys [Array<Symbol>] Key path within metadata
      # @return [Object, nil]
      def dig_metadata(unit, *keys)
        return nil unless unit.is_a?(Hash)

        nested = dig_either(fetch_either(unit, :metadata), keys)
        return nested unless nested.nil?

        keys.size == 1 ? fetch_either(unit, keys.first) : nil
      end

      # Walk a key path through nested hashes, trying both key forms.
      #
      # @param hash [Object] Starting hash (nil-safe)
      # @param keys [Array<Symbol>] Key path
      # @return [Object, nil]
      def dig_either(hash, keys)
        keys.reduce(hash) do |acc, key|
          break nil unless acc.is_a?(Hash)

          fetch_either(acc, key)
        end
      end

      # Fetch a key trying its symbol form, then its string form.
      #
      # @param hash [Object] Hash to read (nil-safe)
      # @param key [Symbol, String] Key to fetch
      # @return [Object, nil]
      def fetch_either(hash, key)
        return nil unless hash.is_a?(Hash)

        value = hash[key]
        value.nil? ? hash[key.to_s] : value
      end

      # Build a Candidate struct compatible with SearchExecutor::Candidate.
      #
      # @return [Candidate-like Struct]
      def build_candidate(identifier:, score:, source:, metadata:, matched_fields: nil)
        SearchExecutor::Candidate.new(
          identifier: identifier,
          score: score,
          source: source,
          metadata: metadata,
          matched_fields: matched_fields
        )
      end
    end
  end
end
