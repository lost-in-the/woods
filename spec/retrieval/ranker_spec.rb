# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/search_executor'
require 'woods/retrieval/query_classifier'
require 'woods/retrieval/ranker'
require 'woods/retrieval/context_assembler'
require 'woods/storage/metadata_store'
require 'woods/storage/graph_store'

RSpec.describe Woods::Retrieval::Ranker do
  let(:metadata_store) { instance_double(Woods::Storage::MetadataStore::Interface) }
  let(:ranker) { described_class.new(metadata_store: metadata_store) }
  let(:classifier) { Woods::Retrieval::QueryClassifier.new }

  # Helper to build Candidate structs
  def candidate(identifier:, score:, source: :vector, metadata: {}, matched_fields: nil)
    Woods::Retrieval::SearchExecutor::Candidate.new(
      identifier: identifier,
      score: score,
      source: source,
      metadata: metadata,
      matched_fields: matched_fields
    )
  end

  # Helper to build a Classification
  def classification(intent: :understand, scope: :focused, target_type: nil, framework_context: false)
    Woods::Retrieval::QueryClassifier::Classification.new(
      intent: intent,
      scope: scope,
      target_type: target_type,
      framework_context: framework_context,
      keywords: []
    )
  end

  # Default: metadata store returns nil (unknown unit)
  before do
    allow(metadata_store).to receive(:find).and_return(nil)
    # find_batch delegates to individual find stubs
    allow(metadata_store).to receive(:find_batch) do |ids|
      ids.each_with_object({}) do |id, result|
        data = metadata_store.find(id)
        result[id] = data if data
      end
    end
  end

  # ── #rank ────────────────────────────────────────────────────────────

  describe '#rank' do
    it 'returns empty array for empty candidates' do
      result = ranker.rank([], classification: classification)
      expect(result).to eq([])
    end

    it 'returns candidates sorted by weighted score' do
      candidates = [
        candidate(identifier: 'Low', score: 0.1, source: :vector),
        candidate(identifier: 'High', score: 0.9, source: :vector),
        candidate(identifier: 'Mid', score: 0.5, source: :vector)
      ]

      result = ranker.rank(candidates, classification: classification)

      expect(result.map(&:identifier)).to eq(%w[High Mid Low])
    end

    it 'returns Candidate structs' do
      candidates = [candidate(identifier: 'User', score: 0.8)]

      result = ranker.rank(candidates, classification: classification)

      expect(result.first).to respond_to(:identifier, :score, :source, :metadata)
    end
  end

  # ── RRF (Reciprocal Rank Fusion) ───────────────────────────────────

  describe 'Reciprocal Rank Fusion' do
    it 'merges candidates from multiple sources using RRF' do
      candidates = [
        candidate(identifier: 'A', score: 0.9, source: :vector),
        candidate(identifier: 'B', score: 0.7, source: :vector),
        candidate(identifier: 'B', score: 0.8, source: :keyword),
        candidate(identifier: 'C', score: 0.6, source: :keyword)
      ]

      result = ranker.rank(candidates, classification: classification)

      # B appears in both sources, so should rank higher than single-source candidates
      b_index = result.index { |c| c.identifier == 'B' }
      c_index = result.index { |c| c.identifier == 'C' }
      expect(b_index).to be < c_index
    end

    it 'does not apply RRF for single-source candidates' do
      candidates = [
        candidate(identifier: 'A', score: 0.9, source: :vector),
        candidate(identifier: 'B', score: 0.7, source: :vector)
      ]

      # All from same source — no RRF merge, just weighted scoring
      result = ranker.rank(candidates, classification: classification)

      expect(result.map(&:identifier)).to eq(%w[A B])
    end

    it 'deduplicates identifiers across sources via RRF' do
      candidates = [
        candidate(identifier: 'User', score: 0.8, source: :vector),
        candidate(identifier: 'User', score: 0.6, source: :keyword),
        candidate(identifier: 'User', score: 0.5, source: :graph)
      ]

      result = ranker.rank(candidates, classification: classification)

      identifiers = result.map(&:identifier)
      expect(identifiers.count('User')).to eq(1)
    end

    it 'boosts candidates appearing in more sources' do
      candidates = [
        candidate(identifier: 'Popular', score: 0.5, source: :vector),
        candidate(identifier: 'Popular', score: 0.5, source: :keyword),
        candidate(identifier: 'Popular', score: 0.5, source: :graph),
        candidate(identifier: 'OneSource', score: 0.9, source: :vector)
      ]

      result = ranker.rank(candidates, classification: classification)

      # Popular appears in 3 sources with RRF boost
      popular_idx = result.index { |c| c.identifier == 'Popular' }
      one_source_idx = result.index { |c| c.identifier == 'OneSource' }
      expect(popular_idx).to be < one_source_idx
    end

    # B-073 / #185 — raw RRF values live on a ~1/(k+1) ≈ 0.016 scale while
    # every other signal is 0.0–1.0. Fed raw into the weighted sum, the 0.40
    # semantic weight contributed at most ~0.02, so the recency spread alone
    # (0.7 * 0.15 = 0.105) out-voted RRF consensus on every fused query.
    describe 'RRF score normalization (B-073)' do
      it 'lets multi-source consensus outrank a recency advantage after fusion' do
        dormant_meta = { 'metadata' => { 'git' => { 'change_frequency' => 'dormant' } } }
        hot_meta = { 'metadata' => { 'git' => { 'change_frequency' => 'hot' } } }
        allow(metadata_store).to receive(:find).with('FusedDormant').and_return(dormant_meta)
        allow(metadata_store).to receive(:find).with('SingleHot').and_return(hot_meta)

        candidates = [
          candidate(identifier: 'FusedDormant', score: 0.9, source: :vector),
          candidate(identifier: 'FusedDormant', score: 0.9, source: :keyword),
          candidate(identifier: 'SingleHot', score: 0.8, source: :vector)
        ]

        result = ranker.rank(candidates, classification: classification)

        # Pre-fix, SingleHot won on recency because the fused semantic
        # signal was numerically irrelevant (~0.013 vs ~0.006).
        expect(result.first.identifier).to eq('FusedDormant')
      end

      it 'min-max normalizes fused scores across the merged candidate list' do
        candidates = [
          candidate(identifier: 'Both', score: 0.9, source: :vector),
          candidate(identifier: 'Both', score: 0.9, source: :keyword),
          candidate(identifier: 'VectorOnly', score: 0.5, source: :vector),
          candidate(identifier: 'KeywordOnly', score: 0.4, source: :keyword)
        ]

        fused = ranker.send(:apply_rrf, candidates)
        scores = fused.to_h { |c| [c.identifier, c.score] }

        expect(scores['Both']).to eq(1.0)
        expect(scores.values.min).to eq(0.0)
        expect(scores.values).to all(be_between(0.0, 1.0))
      end

      it 'maps the degenerate all-equal case to 1.0, not 0.0' do
        # A top-ranked in vector, B top-ranked in keyword — identical RRF
        # sums. Zero spread must read as full-strength agreement.
        candidates = [
          candidate(identifier: 'A', score: 0.9, source: :vector),
          candidate(identifier: 'B', score: 0.8, source: :keyword)
        ]

        fused = ranker.send(:apply_rrf, candidates)

        expect(fused.map(&:score)).to all(eq(1.0))
      end

      it 'carries matched_fields through the RRF merge so the keyword signal survives fusion' do
        candidates = [
          candidate(identifier: 'NoFields', score: 0.9, source: :vector),
          candidate(identifier: 'WithFields', score: 0.9, source: :keyword,
                    matched_fields: %w[identifier description])
        ]

        result = ranker.rank(candidates, classification: classification)

        # Equal RRF (both top of their source) — the preserved keyword
        # signal is the only discriminator.
        expect(result.first.identifier).to eq('WithFields')
        expect(result.first.matched_fields).to eq(%w[identifier description])
      end
    end
  end

  # ── Keyword signal (B-073) ─────────────────────────────────────────

  describe 'keyword score' do
    it 'ranks a candidate with matched fields above one without, all else equal' do
      with_fields = candidate(identifier: 'Matched', score: 0.5, source: :keyword,
                              matched_fields: %w[identifier file_path])
      without_fields = candidate(identifier: 'Unmatched', score: 0.5, source: :keyword)

      result = ranker.rank([without_fields, with_fields], classification: classification)

      expect(result.first.identifier).to eq('Matched')
    end

    it 'caps the keyword signal at 1.0 (four or more matched fields)' do
      many = candidate(identifier: 'Many', score: 0.5, source: :keyword,
                       matched_fields: %w[a b c d e f])
      four = candidate(identifier: 'Four', score: 0.5, source: :keyword,
                       matched_fields: %w[a b c d])

      result = ranker.rank([many, four], classification: classification)
      scores = result.to_h { |c| [c.identifier, c.score] }

      expect(scores['Many']).to eq(scores['Four'])
    end
  end

  # ── Score rewriting (B-073) ────────────────────────────────────────

  describe 'weighted score rewriting' do
    it 'rewrites each candidate score to its weighted score so downstream sorts agree' do
      result = ranker.rank([candidate(identifier: 'User', score: 0.8)], classification: classification)

      # semantic 0.8*0.40 + keyword 0.0*0.20 + recency 0.5*0.15 +
      # importance 0.5*0.10 + type_match 0.5*0.10 + diversity 1.0*0.05
      expect(result.first.score).to be_within(1e-9).of(0.545)
    end

    it 'returns candidates with scores in descending ranked order' do
      hot_meta = { 'metadata' => { 'git' => { 'change_frequency' => 'hot' } } }
      dormant_meta = { 'metadata' => { 'git' => { 'change_frequency' => 'dormant' } } }
      allow(metadata_store).to receive(:find).with('Hot').and_return(hot_meta)
      allow(metadata_store).to receive(:find).with('Dormant').and_return(dormant_meta)

      result = ranker.rank(
        [candidate(identifier: 'Dormant', score: 0.9), candidate(identifier: 'Hot', score: 0.5)],
        classification: classification
      )

      expect(result.map(&:score)).to eq(result.map(&:score).sort.reverse)
    end

    it 'does not mutate the caller-supplied candidate structs' do
      original = candidate(identifier: 'User', score: 0.8)

      ranker.rank([original], classification: classification)

      expect(original.score).to eq(0.8)
    end
  end

  # ── Signal scoring ─────────────────────────────────────────────────

  describe 'semantic score' do
    it 'uses candidate score as semantic signal' do
      high = candidate(identifier: 'High', score: 0.95)
      low = candidate(identifier: 'Low', score: 0.05)

      result = ranker.rank([low, high], classification: classification)

      expect(result.first.identifier).to eq('High')
    end
  end

  describe 'recency score' do
    it 'scores hot units higher than dormant' do
      allow(metadata_store).to receive(:find).with('Hot')
                                             .and_return({ metadata: { git: { change_frequency: :hot } } })
      allow(metadata_store).to receive(:find).with('Dormant')
                                             .and_return({ metadata: { git: { change_frequency: :dormant } } })

      hot = candidate(identifier: 'Hot', score: 0.5)
      dormant = candidate(identifier: 'Dormant', score: 0.5)

      result = ranker.rank([dormant, hot], classification: classification)

      expect(result.first.identifier).to eq('Hot')
    end

    it 'returns 0.5 for unknown units' do
      unknown = candidate(identifier: 'Unknown', score: 0.5)

      # metadata_store returns nil
      result = ranker.rank([unknown], classification: classification)
      expect(result.first.identifier).to eq('Unknown')
    end
  end

  describe 'importance score' do
    it 'scores high importance units higher' do
      allow(metadata_store).to receive(:find).with('Important').and_return({
                                                                             metadata: { importance: :high }
                                                                           })
      allow(metadata_store).to receive(:find).with('Trivial').and_return({
                                                                           metadata: { importance: :low }
                                                                         })

      important = candidate(identifier: 'Important', score: 0.5)
      trivial = candidate(identifier: 'Trivial', score: 0.5)

      result = ranker.rank([trivial, important], classification: classification)

      expect(result.first.identifier).to eq('Important')
    end
  end

  # #218 / B-105. Chunked units embed as `Identifier#chunk_N`, but metadata
  # and the graph are keyed on the bare identifier — so passing the raw
  # candidate id to find_batch missed every chunk and recency, importance,
  # type_match and diversity all collapsed to their neutral values, leaving
  # semantic+keyword to rank alone. Precisely on chunked corpora, which is
  # where ranking matters most. The bootstrapper and the assembler already
  # strip the suffix; the ranker was the one consumer that did not.
  describe 'chunk-suffixed candidates' do
    it 'looks metadata up by base identifier' do
      allow(metadata_store).to receive(:find).with('User').and_return({
                                                                        'metadata' => { 'importance' => 'high' }
                                                                      })

      result = ranker.rank([candidate(identifier: 'User#chunk_3', score: 0.5)],
                           classification: classification)

      expect(metadata_store).to have_received(:find).with('User')
      expect(result.first.identifier).to eq('User#chunk_3')
    end

    it 'scores a chunk the same as its unchunked twin' do
      meta = { 'metadata' => { 'importance' => 'high' } }
      allow(metadata_store).to receive(:find).with('User').and_return(meta)

      chunked = ranker.rank([candidate(identifier: 'User#chunk_0', score: 0.5)],
                            classification: classification).first.score
      whole = ranker.rank([candidate(identifier: 'User', score: 0.5)],
                          classification: classification).first.score

      expect(chunked).to be_within(0.0001).of(whole)
    end

    # The failure this prevents: a high-importance chunked unit losing to a
    # low-importance unchunked one purely because its metadata was missed.
    it 'ranks an important chunked unit above an unimportant whole one' do
      allow(metadata_store).to receive(:find).with('Important')
                                             .and_return({ 'metadata' => { 'importance' => 'high' } })
      allow(metadata_store).to receive(:find).with('Trivial')
                                             .and_return({ 'metadata' => { 'importance' => 'low' } })

      result = ranker.rank(
        [candidate(identifier: 'Trivial', score: 0.5), candidate(identifier: 'Important#chunk_1', score: 0.5)],
        classification: classification
      )

      expect(result.first.identifier).to eq('Important#chunk_1')
    end

    it 'de-duplicates the batch lookup across chunks of one unit' do
      allow(metadata_store).to receive(:find).with('User').and_return({ 'metadata' => {} })

      ranker.rank(
        [candidate(identifier: 'User#chunk_0', score: 0.5), candidate(identifier: 'User#chunk_1', score: 0.4)],
        classification: classification
      )

      expect(metadata_store).to have_received(:find_batch).with(['User'])
    end
  end

  # The metadata store returns STRING keys on every real backend (SQLite
  # via JSON.parse, InMemory via stringify_keys). These specs use that
  # shape — with symbol-only key access, all four metadata signals scored
  # every unit at its neutral fallback and these would fail.
  describe 'string-keyed metadata (real store shape)' do
    it 'scores recency from string-keyed git metadata' do
      hot_meta = { 'metadata' => { 'git' => { 'change_frequency' => 'hot' } } }
      dormant_meta = { 'metadata' => { 'git' => { 'change_frequency' => 'dormant' } } }
      allow(metadata_store).to receive(:find).with('Hot').and_return(hot_meta)
      allow(metadata_store).to receive(:find).with('Dormant').and_return(dormant_meta)

      hot = candidate(identifier: 'Hot', score: 0.5)
      dormant = candidate(identifier: 'Dormant', score: 0.5)

      result = ranker.rank([dormant, hot], classification: classification)

      expect(result.first.identifier).to eq('Hot')
    end

    it 'scores importance from string-keyed metadata' do
      allow(metadata_store).to receive(:find).with('Important')
                                             .and_return({ 'metadata' => { 'importance' => 'high' } })
      allow(metadata_store).to receive(:find).with('Trivial')
                                             .and_return({ 'metadata' => { 'importance' => 'low' } })

      important = candidate(identifier: 'Important', score: 0.5)
      trivial = candidate(identifier: 'Trivial', score: 0.5)

      result = ranker.rank([trivial, important], classification: classification)

      expect(result.first.identifier).to eq('Important')
    end

    it 'matches target_type from the string-keyed top-level type field' do
      allow(metadata_store).to receive(:find).with('UserModel')
                                             .and_return({ 'type' => 'model', 'metadata' => {} })
      allow(metadata_store).to receive(:find).with('UserController')
                                             .and_return({ 'type' => 'controller', 'metadata' => {} })

      model_unit = candidate(identifier: 'UserModel', score: 0.5)
      controller_unit = candidate(identifier: 'UserController', score: 0.5)

      cls = classification(target_type: :model)
      result = ranker.rank([controller_unit, model_unit], classification: cls)

      expect(result.first.identifier).to eq('UserModel')
    end
  end

  describe 'pagerank importance integration' do
    let(:graph_store) { instance_double(Woods::Storage::GraphStore::Interface) }
    let(:ranker) { described_class.new(metadata_store: metadata_store, graph_store: graph_store) }

    it 'prefers high-pagerank candidates over low-pagerank ones' do
      allow(graph_store).to receive(:pagerank).and_return(
        'Hot' => 0.9, 'Warm' => 0.1, 'Cold' => 0.001
      )
      allow(metadata_store).to receive(:find).and_return(nil)

      candidates = %w[Cold Warm Hot].map { |id| candidate(identifier: id, score: 0.5) }

      result = ranker.rank(candidates, classification: classification)

      expect(result.map(&:identifier)).to eq(%w[Hot Warm Cold])
    end

    it 'uses rank-percentile rather than raw pagerank values' do
      # Raw values span 4 orders of magnitude, but percentile compresses
      # ranking into 1.0 (top) down to 1/n (bottom) — order is what matters.
      allow(graph_store).to receive(:pagerank).and_return(
        'Top' => 0.9, 'Mid' => 0.0005, 'Bottom' => 0.00001
      )
      allow(metadata_store).to receive(:find).and_return(nil)

      candidates = %w[Bottom Mid Top].map { |id| candidate(identifier: id, score: 0.5) }

      result = ranker.rank(candidates, classification: classification)

      expect(result.map(&:identifier)).to eq(%w[Top Mid Bottom])
    end

    it 'falls back to bucketed metadata importance for identifiers absent from pagerank' do
      # Known is the lowest-ranked unit in a 5-node graph (percentile ≈ 0.2)
      allow(graph_store).to receive(:pagerank).and_return(
        'A' => 0.9, 'B' => 0.7, 'C' => 0.5, 'D' => 0.3, 'Known' => 0.01
      )
      allow(metadata_store).to receive(:find).with('Known').and_return(nil)
      allow(metadata_store).to receive(:find).with('NewUnit')
                                             .and_return({ metadata: { importance: :high } })

      known = candidate(identifier: 'Known', score: 0.5)
      # NewUnit isn't in the graph yet, but its bucketed importance is :high (=> 1.0)
      new_unit = candidate(identifier: 'NewUnit', score: 0.5)

      result = ranker.rank([known, new_unit], classification: classification)

      expect(result.first.identifier).to eq('NewUnit')
    end

    it 'falls back entirely when graph store returns an empty pagerank hash' do
      allow(graph_store).to receive(:pagerank).and_return({})
      allow(metadata_store).to receive(:find).with('Important')
                                             .and_return({ metadata: { importance: :high } })
      allow(metadata_store).to receive(:find).with('Trivial')
                                             .and_return({ metadata: { importance: :low } })

      candidates = [
        candidate(identifier: 'Trivial', score: 0.5),
        candidate(identifier: 'Important', score: 0.5)
      ]

      result = ranker.rank(candidates, classification: classification)

      expect(result.first.identifier).to eq('Important')
    end

    it 'swallows graph store errors and falls back to bucketed importance' do
      allow(graph_store).to receive(:pagerank).and_raise(StandardError, 'graph unavailable')
      allow(metadata_store).to receive(:find).with('Important')
                                             .and_return({ metadata: { importance: :high } })

      candidates = [candidate(identifier: 'Important', score: 0.5)]

      expect { ranker.rank(candidates, classification: classification) }.not_to raise_error
    end

    it 'computes pagerank map once even across multiple rank() calls' do
      allow(graph_store).to receive(:pagerank).and_return('A' => 0.9, 'B' => 0.1).once
      allow(metadata_store).to receive(:find).and_return(nil)

      2.times do
        ranker.rank([candidate(identifier: 'A', score: 0.5)], classification: classification)
      end
    end

    # B-073 / #185 — the memo was never invalidated, so after the MCP
    # reload tool swapped a fresh graph into the shared store wrapper
    # (Bootstrapper.reload_stores! → replace_graph), importance kept
    # scoring against the pre-reload PageRank for the process lifetime.
    describe '#invalidate_pagerank_cache!' do
      it 'recomputes importance from the current graph after invalidation' do
        # First call: A dominates. Second call (post-swap): B dominates.
        allow(graph_store).to receive(:pagerank).and_return(
          { 'A' => 0.9, 'B' => 0.1 },
          { 'A' => 0.01, 'B' => 0.99 }
        )
        allow(metadata_store).to receive(:find).and_return(nil)
        candidates = [candidate(identifier: 'A', score: 0.5), candidate(identifier: 'B', score: 0.5)]

        first = ranker.rank(candidates, classification: classification)
        expect(first.first.identifier).to eq('A')

        ranker.invalidate_pagerank_cache!

        second = ranker.rank(candidates, classification: classification)
        expect(second.first.identifier).to eq('B')
      end
    end
  end

  describe 'ranker without graph_store (backwards compat)' do
    it 'falls back to bucketed metadata importance' do
      allow(metadata_store).to receive(:find).with('Important')
                                             .and_return({ metadata: { importance: :high } })
      allow(metadata_store).to receive(:find).with('Trivial')
                                             .and_return({ metadata: { importance: :low } })

      ranker_without_graph = described_class.new(metadata_store: metadata_store)
      candidates = [
        candidate(identifier: 'Trivial', score: 0.5),
        candidate(identifier: 'Important', score: 0.5)
      ]

      result = ranker_without_graph.rank(candidates, classification: classification)

      expect(result.first.identifier).to eq('Important')
    end
  end

  describe 'type match score' do
    it 'boosts results matching query target_type' do
      allow(metadata_store).to receive(:find).with('UserModel')
                                             .and_return({ type: :model, metadata: { type: :model } })
      allow(metadata_store).to receive(:find).with('UserController')
                                             .and_return({ type: :controller, metadata: { type: :controller } })

      model_unit = candidate(identifier: 'UserModel', score: 0.5)
      controller_unit = candidate(identifier: 'UserController', score: 0.5)

      cls = classification(target_type: :model)
      result = ranker.rank([controller_unit, model_unit], classification: cls)

      expect(result.first.identifier).to eq('UserModel')
    end

    it 'returns neutral score when no target_type specified' do
      allow(metadata_store).to receive(:find).with('A').and_return({ metadata: { type: :model } })
      allow(metadata_store).to receive(:find).with('B').and_return({ metadata: { type: :controller } })

      a = candidate(identifier: 'A', score: 0.6)
      b = candidate(identifier: 'B', score: 0.5)

      # No target_type — type_match should not affect order
      result = ranker.rank([b, a], classification: classification(target_type: nil))
      expect(result.first.identifier).to eq('A')
    end
  end

  # ── Diversity penalty ──────────────────────────────────────────────

  describe 'diversity penalty' do
    it 'penalizes repeated namespace/type combinations' do
      # Three models in same namespace vs one controller
      %w[Model1 Model2 Model3].each do |id|
        allow(metadata_store).to receive(:find).with(id).and_return({
                                                                      metadata: { namespace: 'Admin', type: :model }
                                                                    })
      end
      allow(metadata_store).to receive(:find).with('Controller1').and_return({
                                                                               metadata: { namespace: 'Public',
                                                                                           type: :controller }
                                                                             })

      candidates = [
        candidate(identifier: 'Model1', score: 0.8),
        candidate(identifier: 'Model2', score: 0.75),
        candidate(identifier: 'Controller1', score: 0.7),
        candidate(identifier: 'Model3', score: 0.65)
      ]

      result = ranker.rank(candidates, classification: classification)

      # Controller should be boosted relative to Model3 due to diversity
      ctrl_idx = result.index { |c| c.identifier == 'Controller1' }
      model3_idx = result.index { |c| c.identifier == 'Model3' }
      expect(ctrl_idx).to be < model3_idx
    end

    it 'caps diversity penalty at 0.5' do
      # Even with many repetitions, penalty should not exceed 0.5
      10.times do |i|
        allow(metadata_store).to receive(:find).with("Unit#{i}").and_return({
                                                                              metadata: { namespace: 'Same',
                                                                                          type: :model }
                                                                            })
      end

      candidates = (0...10).map do |i|
        candidate(identifier: "Unit#{i}", score: 0.9 - (i * 0.01))
      end

      result = ranker.rank(candidates, classification: classification)

      # All units should still appear (penalty doesn't remove them)
      expect(result.size).to eq(10)
    end
  end

  # ── Metadata caching (Bug M-4 fix) ─────────────────────────────────

  describe 'metadata store lookup count' do
    it 'calls find_batch once for all candidates (batch lookup)' do
      allow(metadata_store).to receive(:find).with('User').and_return({
                                                                        metadata: { namespace: 'App', type: :model }
                                                                      })

      candidates = [candidate(identifier: 'User', score: 0.8)]

      expect(metadata_store).to receive(:find_batch).with(['User']).once do |ids|
        ids.to_h { |id| [id, metadata_store.find(id)] }.compact
      end

      ranker.rank(candidates, classification: classification)
    end

    it 'calls find_batch once even with diversity penalty active' do
      %w[A B C].each do |id|
        allow(metadata_store).to receive(:find).with(id).and_return({
                                                                      metadata: { namespace: 'Same', type: :model }
                                                                    })
      end

      candidates = [
        candidate(identifier: 'A', score: 0.9),
        candidate(identifier: 'B', score: 0.8),
        candidate(identifier: 'C', score: 0.7)
      ]

      expect(metadata_store).to receive(:find_batch).once do |ids|
        ids.to_h { |id| [id, metadata_store.find(id)] }.compact
      end

      ranker.rank(candidates, classification: classification)
    end
  end

  # ── Weight constants ───────────────────────────────────────────────

  describe 'WEIGHTS' do
    it 'sums to 1.0' do
      expect(described_class::WEIGHTS.values.sum).to be_within(0.001).of(1.0)
    end

    it 'includes all expected signals' do
      expect(described_class::WEIGHTS.keys).to contain_exactly(
        :semantic, :keyword, :recency, :importance, :type_match, :diversity
      )
    end
  end

  describe 'RRF_K' do
    it 'is 60 (standard constant)' do
      expect(described_class::RRF_K).to eq(60)
    end
  end

  # ── Integration with real classifier ───────────────────────────────

  describe 'integration with QueryClassifier' do
    it 'works with a real Classification struct' do
      cls = classifier.classify('Where is the User model defined?')

      candidates = [
        candidate(identifier: 'User', score: 0.9),
        candidate(identifier: 'Admin', score: 0.5)
      ]

      allow(metadata_store).to receive(:find).with('User').and_return({
                                                                        metadata: { type: :model, importance: :high }
                                                                      })

      result = ranker.rank(candidates, classification: cls)

      expect(result.first.identifier).to eq('User')
    end
  end

  # ── Ranked order survives context assembly (B-073) ─────────────────

  describe 'ranked order flows through ContextAssembler' do
    # Regression — the ranker used to return candidates in weighted order
    # but with their ORIGINAL retrieval scores; ContextAssembler's
    # assemble_section re-sorts by score, so recency/importance/type_match/
    # diversity never influenced section content or budget truncation.
    it 'places a ranker-demoted candidate after a promoted one even when its raw score was higher' do
      allow(metadata_store).to receive(:find).with('Demoted').and_return(
        'identifier' => 'Demoted', 'type' => 'model', 'file_path' => 'app/models/demoted.rb',
        'source_code' => 'DEMOTED_CONTENT',
        'metadata' => { 'git' => { 'change_frequency' => 'dormant' } }
      )
      allow(metadata_store).to receive(:find).with('Promoted').and_return(
        'identifier' => 'Promoted', 'type' => 'model', 'file_path' => 'app/models/promoted.rb',
        'source_code' => 'PROMOTED_CONTENT',
        'metadata' => { 'git' => { 'change_frequency' => 'hot' } }
      )

      demoted = candidate(identifier: 'Demoted', score: 0.9)   # higher raw retrieval score, dormant
      promoted = candidate(identifier: 'Promoted', score: 0.8) # hot recency wins the weighted rank

      ranked = ranker.rank([demoted, promoted], classification: classification)
      expect(ranked.map(&:identifier)).to eq(%w[Promoted Demoted])

      assembler = Woods::Retrieval::ContextAssembler.new(metadata_store: metadata_store)
      result = assembler.assemble(candidates: ranked, classification: classification)

      promoted_pos = result.context.index('PROMOTED_CONTENT')
      demoted_pos = result.context.index('DEMOTED_CONTENT')
      expect(promoted_pos).to be < demoted_pos
    end
  end
end
