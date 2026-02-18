# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/cost_model/provider_pricing'

RSpec.describe CodebaseIndex::CostModel::ProviderPricing do
  describe '.cost_per_million' do
    it 'returns $0.02 for openai_small' do
      expect(described_class.cost_per_million(:openai_small)).to eq(0.02)
    end

    it 'returns $0.13 for openai_large' do
      expect(described_class.cost_per_million(:openai_large)).to eq(0.13)
    end

    it 'returns $0.06 for voyage_code3' do
      expect(described_class.cost_per_million(:voyage_code3)).to eq(0.06)
    end

    it 'returns $0.00 for ollama' do
      expect(described_class.cost_per_million(:ollama)).to eq(0.00)
    end

    it 'raises ArgumentError for unknown provider' do
      expect { described_class.cost_per_million(:unknown) }
        .to raise_error(ArgumentError, /Unknown embedding provider: :unknown/)
    end
  end

  describe '.default_dimensions' do
    it 'returns 1536 for openai_small' do
      expect(described_class.default_dimensions(:openai_small)).to eq(1536)
    end

    it 'returns 3072 for openai_large' do
      expect(described_class.default_dimensions(:openai_large)).to eq(3072)
    end

    it 'returns 1024 for voyage_code3' do
      expect(described_class.default_dimensions(:voyage_code3)).to eq(1024)
    end

    it 'returns 768 for ollama' do
      expect(described_class.default_dimensions(:ollama)).to eq(768)
    end

    it 'raises ArgumentError for unknown provider' do
      expect { described_class.default_dimensions(:unknown) }
        .to raise_error(ArgumentError, /Unknown embedding provider/)
    end
  end

  describe '.providers' do
    it 'returns all known provider keys' do
      expect(described_class.providers).to contain_exactly(:openai_small, :openai_large, :voyage_code3, :ollama)
    end
  end

  describe 'COSTS_PER_MILLION_TOKENS' do
    it 'is frozen' do
      expect(described_class::COSTS_PER_MILLION_TOKENS).to be_frozen
    end
  end

  describe 'DEFAULT_DIMENSIONS' do
    it 'is frozen' do
      expect(described_class::DEFAULT_DIMENSIONS).to be_frozen
    end
  end
end
