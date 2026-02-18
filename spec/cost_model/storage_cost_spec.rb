# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/cost_model/storage_cost'

RSpec.describe CodebaseIndex::CostModel::StorageCost do
  describe '#bytes_per_vector' do
    it 'calculates for 1536 dimensions' do
      calc = described_class.new(dimensions: 1536)
      # 1536 * 4 * 1.3 = 7,987.2 → ceil to 7988
      expect(calc.bytes_per_vector).to eq(7988)
    end

    it 'calculates for 1024 dimensions' do
      calc = described_class.new(dimensions: 1024)
      # 1024 * 4 * 1.3 = 5,324.8 → ceil to 5325
      expect(calc.bytes_per_vector).to eq(5325)
    end

    it 'calculates for 3072 dimensions' do
      calc = described_class.new(dimensions: 3072)
      # 3072 * 4 * 1.3 = 15,974.4 → ceil to 15975
      expect(calc.bytes_per_vector).to eq(15_975)
    end

    it 'calculates for 256 dimensions' do
      calc = described_class.new(dimensions: 256)
      # 256 * 4 * 1.3 = 1,331.2 → ceil to 1332
      expect(calc.bytes_per_vector).to eq(1332)
    end
  end

  describe '#storage_bytes' do
    subject(:calc) { described_class.new(dimensions: 1536) }

    it 'returns total bytes for a chunk count' do
      # 1250 chunks * 7988 bytes = 9,985,000
      expect(calc.storage_bytes(chunks: 1250)).to eq(1250 * 7988)
    end
  end

  describe '#storage_mb' do
    # BACKEND_MATRIX.md table values (1536-dim):
    # 125 chunks  → 0.97 MB
    # 500 chunks  → 3.8 MB
    # 1250 chunks → 9.6 MB
    # 2500 chunks → 19 MB

    subject(:calc) { described_class.new(dimensions: 1536) }

    it 'approximates the 125-chunk table value' do
      expect(calc.storage_mb(chunks: 125)).to be_within(0.1).of(0.95)
    end

    it 'approximates the 500-chunk table value' do
      expect(calc.storage_mb(chunks: 500)).to be_within(0.3).of(3.81)
    end

    it 'approximates the 1250-chunk table value' do
      expect(calc.storage_mb(chunks: 1250)).to be_within(0.5).of(9.52)
    end

    it 'approximates the 2500-chunk table value' do
      expect(calc.storage_mb(chunks: 2500)).to be_within(1.0).of(19.04)
    end
  end
end
