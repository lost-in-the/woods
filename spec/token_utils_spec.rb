# frozen_string_literal: true

require 'spec_helper'
require 'woods/token_utils'

RSpec.describe Woods::TokenUtils do
  describe '.chars_per_token_for' do
    it 'returns 4.0 for :openai' do
      expect(described_class.chars_per_token_for(:openai)).to eq(4.0)
    end

    it 'returns 1.5 for :ollama' do
      expect(described_class.chars_per_token_for(:ollama)).to eq(1.5)
    end

    it 'falls back to the default for unknown providers' do
      expect(described_class.chars_per_token_for(:anthropic)).to eq(described_class::DEFAULT_CHARS_PER_TOKEN)
    end

    it 'falls back to the default for nil' do
      expect(described_class.chars_per_token_for(nil)).to eq(described_class::DEFAULT_CHARS_PER_TOKEN)
    end

    it 'accepts String provider identifiers and coerces to Symbol' do
      expect(described_class.chars_per_token_for('ollama')).to eq(1.5)
    end
  end

  describe '.estimate_tokens' do
    it 'uses the default (OpenAI) 4.0 ratio' do
      # 40 chars / 4.0 = 10 tokens
      expect(described_class.estimate_tokens('x' * 40)).to eq(10)
    end

    it 'rounds up for partial tokens' do
      # 5 chars / 4.0 = 1.25 → ceil 2
      expect(described_class.estimate_tokens('hello')).to eq(2)
    end
  end

  describe '.estimate_tokens_for' do
    it 'honors the Ollama 1.5 ratio' do
      # 30 chars / 1.5 = 20 tokens
      expect(described_class.estimate_tokens_for('y' * 30, provider: :ollama)).to eq(20)
    end

    it 'falls back to the default ratio for unknown providers' do
      expect(described_class.estimate_tokens_for('z' * 40, provider: :unknown)).to eq(10)
    end
  end
end
