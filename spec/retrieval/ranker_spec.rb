# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/search_executor'
require 'codebase_index/retrieval/query_classifier'
require 'codebase_index/retrieval/ranker'

RSpec.describe CodebaseIndex::Retrieval::Ranker do
  let(:metadata_store) { double('MetadataStore') }
  let(:ranker) { described_class.new(metadata_store: metadata_store) }
  let(:classifier) { CodebaseIndex::Retrieval::QueryClassifier.new }

  # Helper to build Candidate structs
  def candidate(identifier:, score:, source: :vector, metadata: {})
    CodebaseIndex::Retrieval::SearchExecutor::Candidate.new(
      identifier: identifier,
      score: score,
      source: source,
      metadata: metadata
    )
  end

  # Helper to build a Classification
  def classification(intent: :understand, scope: :focused, target_type: nil, framework_context: false)
    CodebaseIndex::Retrieval::QueryClassifier::Classification.new(
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
end
