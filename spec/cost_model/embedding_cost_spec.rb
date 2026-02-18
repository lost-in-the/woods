# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/cost_model/provider_pricing'
require 'codebase_index/cost_model/embedding_cost'

RSpec.describe CodebaseIndex::CostModel::EmbeddingCost do
  subject(:calc) { described_class.new(provider: :openai_small) }

  describe '#full_index_cost' do
    # BACKEND_MATRIX.md table values (OpenAI 3-small at $0.02/1M):
    # 50 units  → ~56K tokens  → $0.001
    # 200 units → ~225K tokens → $0.005
    # 500 units → ~562K tokens → $0.011
    # 1000 units → ~1.1M tokens → $0.022

    it 'matches the 50-unit table value' do
      cost = calc.full_index_cost(units: 50, chunk_multiplier: 2.5)
      # 50 * 2.5 = 125 chunks * 450 = 56,250 tokens → $0.001125
      expect(cost).to be_within(0.001).of(0.001)
    end

    it 'matches the 200-unit table value' do
      cost = calc.full_index_cost(units: 200, chunk_multiplier: 2.5)
      # 200 * 2.5 = 500 chunks * 450 = 225,000 tokens → $0.0045
      expect(cost).to be_within(0.001).of(0.005)
    end

    it 'matches the 500-unit table value' do
      cost = calc.full_index_cost(units: 500, chunk_multiplier: 2.5)
      # 500 * 2.5 = 1250 chunks * 450 = 562,500 tokens → $0.01125
      expect(cost).to be_within(0.002).of(0.011)
    end

    it 'matches the 1000-unit table value' do
      cost = calc.full_index_cost(units: 1000, chunk_multiplier: 2.5)
      # 1000 * 2.5 = 2500 chunks * 450 = 1,125,000 tokens → $0.0225
      expect(cost).to be_within(0.002).of(0.022)
    end

    context 'with openai_large' do
      subject(:large_calc) { described_class.new(provider: :openai_large) }

      it 'matches the 500-unit table value at $0.13/1M' do
        cost = large_calc.full_index_cost(units: 500, chunk_multiplier: 2.5)
        # 562,500 tokens * 0.13 / 1M = $0.073125
        expect(cost).to be_within(0.005).of(0.073)
      end
    end

    context 'with voyage_code3' do
      subject(:voyage_calc) { described_class.new(provider: :voyage_code3) }

      it 'matches the 500-unit table value at $0.06/1M' do
        cost = voyage_calc.full_index_cost(units: 500, chunk_multiplier: 2.5)
        # 562,500 tokens * 0.06 / 1M = $0.03375
        expect(cost).to be_within(0.002).of(0.034)
      end
    end

    context 'with ollama' do
      subject(:ollama_calc) { described_class.new(provider: :ollama) }

      it 'is always zero' do
        expect(ollama_calc.full_index_cost(units: 1000)).to eq(0.0)
      end
    end
  end

  describe '#incremental_cost' do
    it 'calculates cost for a single merge (5 changed units)' do
      cost = calc.incremental_cost(changed_units: 5, chunk_multiplier: 2.5)
      # 5 * 2.5 = 13 chunks (ceil) * 450 = 5,850 tokens → $0.000117
      expect(cost).to be_within(0.0002).of(0.0001)
    end
  end

  describe '#monthly_query_cost' do
    it 'calculates monthly cost for 100 daily queries' do
      cost = calc.monthly_query_cost(daily_queries: 100)
      # 100 * 30 * 100 = 300,000 tokens → $0.006
      expect(cost).to eq(0.006)
    end

    it 'calculates monthly cost for 1000 daily queries' do
      cost = calc.monthly_query_cost(daily_queries: 1000)
      # 1000 * 30 * 100 = 3,000,000 tokens → $0.06
      expect(cost).to eq(0.06)
    end
  end

  describe '#yearly_incremental_cost' do
    it 'calculates yearly cost for 2400 merges' do
      cost = calc.yearly_incremental_cost(merges_per_year: 2400, changed_units_per_merge: 5)
      # Per merge: 13 chunks * 450 = 5,850 tokens
      # Yearly: 5,850 * 2400 = 14,040,000 tokens → $0.28
      expect(cost).to be_within(0.05).of(0.26)
    end
  end

  describe '#total_tokens' do
    it 'calculates total tokens from units and chunk multiplier' do
      # 500 units * 2.5 = 1250 chunks * 450 = 562,500
      expect(calc.total_tokens(500, 2.5)).to eq(562_500)
    end

    it 'ceils the chunk count for fractional results' do
      # 3 units * 2.5 = 7.5 → ceil to 8 chunks * 450 = 3,600
      expect(calc.total_tokens(3, 2.5)).to eq(3600)
    end
  end
end
