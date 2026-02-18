# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/cost_model'

RSpec.describe CodebaseIndex::CostModel::Estimator do
  subject(:estimator) do
    described_class.new(
      units: 500,
      chunk_multiplier: 2.5,
      embedding_provider: :openai_small,
      dimensions: 1536,
      daily_queries: 100
    )
  end

  describe '#initialize' do
    it 'stores all configuration attributes' do
      expect(estimator.units).to eq(500)
      expect(estimator.chunk_multiplier).to eq(2.5)
      expect(estimator.embedding_provider).to eq(:openai_small)
      expect(estimator.dimensions).to eq(1536)
      expect(estimator.daily_queries).to eq(100)
    end

    it 'defaults dimensions from provider when not specified' do
      est = described_class.new(units: 100, embedding_provider: :voyage_code3)
      expect(est.dimensions).to eq(1024)
    end

    it 'defaults chunk_multiplier to 2.5' do
      est = described_class.new(units: 100, embedding_provider: :openai_small)
      expect(est.chunk_multiplier).to eq(2.5)
    end

    it 'defaults daily_queries to 100' do
      est = described_class.new(units: 100, embedding_provider: :openai_small)
      expect(est.daily_queries).to eq(100)
    end
  end

  describe '#full_index_cost' do
    it 'returns the full-index embedding cost' do
      # 500 * 2.5 = 1250 chunks * 450 = 562,500 tokens * $0.02/1M = $0.01125
      expect(estimator.full_index_cost).to be_within(0.002).of(0.011)
    end
  end

  describe '#incremental_per_merge_cost' do
    it 'returns cost for a single merge with default 5 changed units' do
      cost = estimator.incremental_per_merge_cost
      expect(cost).to be > 0
      expect(cost).to be < 0.001
    end
  end

  describe '#monthly_query_cost' do
    it 'returns monthly query embedding cost' do
      # 100 queries/day * 30 * 100 tokens * $0.02/1M = $0.006
      expect(estimator.monthly_query_cost).to eq(0.006)
    end
  end

  describe '#yearly_incremental_cost' do
    it 'returns yearly incremental re-embedding cost' do
      cost = estimator.yearly_incremental_cost
      expect(cost).to be_within(0.05).of(0.28)
    end
  end

  describe '#total_chunks' do
    it 'returns units * chunk_multiplier ceiled' do
      expect(estimator.total_chunks).to eq(1250)
    end
  end

  describe '#storage_bytes' do
    it 'returns total vector storage in bytes' do
      # 1250 chunks * (1536 * 4 * 1.3).ceil = 1250 * 7988 = 9,985,000
      expect(estimator.storage_bytes).to eq(1250 * 7988)
    end
  end

  describe '#storage_mb' do
    it 'returns total vector storage in megabytes' do
      expect(estimator.storage_mb).to be_within(0.5).of(9.52)
    end
  end

  describe '#to_h' do
    it 'returns a complete cost breakdown hash' do
      result = estimator.to_h

      expect(result).to include(
        full_index_cost: a_kind_of(Float),
        incremental_per_merge_cost: a_kind_of(Float),
        monthly_query_cost: a_kind_of(Float),
        yearly_incremental_cost: a_kind_of(Float),
        storage_bytes: a_kind_of(Integer),
        storage_mb: a_kind_of(Float),
        total_chunks: 1250,
        units: 500,
        chunk_multiplier: 2.5,
        embedding_provider: :openai_small,
        dimensions: 1536,
        daily_queries: 100
      )
    end
  end

  context 'with ollama (zero cost)' do
    subject(:free_estimator) do
      described_class.new(units: 1000, embedding_provider: :ollama)
    end

    it 'has zero embedding costs' do
      expect(free_estimator.full_index_cost).to eq(0.0)
      expect(free_estimator.incremental_per_merge_cost).to eq(0.0)
      expect(free_estimator.monthly_query_cost).to eq(0.0)
      expect(free_estimator.yearly_incremental_cost).to eq(0.0)
    end

    it 'still has non-zero storage' do
      expect(free_estimator.storage_bytes).to be > 0
    end
  end
end
