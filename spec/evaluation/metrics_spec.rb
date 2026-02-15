# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/evaluation/metrics'

RSpec.describe CodebaseIndex::Evaluation::Metrics do
  describe '.precision_at_k' do
    it 'returns 1.0 when all top-k are relevant' do
      retrieved = %w[A B C D E]
      relevant = %w[A B C D E]

      expect(described_class.precision_at_k(retrieved, relevant, cutoff: 5)).to eq(1.0)
    end

    it 'returns 0.6 when 3 of 5 are relevant' do
      retrieved = %w[A B X C Y]
      relevant = %w[A B C]

      expect(described_class.precision_at_k(retrieved, relevant, cutoff: 5)).to eq(0.6)
    end

    it 'returns 0.0 when no top-k are relevant' do
      retrieved = %w[X Y Z]
      relevant = %w[A B C]

      expect(described_class.precision_at_k(retrieved, relevant, cutoff: 3)).to eq(0.0)
    end

    it 'handles cutoff larger than retrieved list' do
      retrieved = %w[A B]
      relevant = %w[A B C]

      expect(described_class.precision_at_k(retrieved, relevant, cutoff: 5)).to eq(0.4)
    end

    it 'returns 0.0 for empty retrieved' do
      expect(described_class.precision_at_k([], %w[A], cutoff: 5)).to eq(0.0)
    end

    it 'returns 0.0 for empty relevant' do
      expect(described_class.precision_at_k(%w[A], [], cutoff: 5)).to eq(0.0)
    end

    it 'defaults cutoff to 5' do
      retrieved = %w[A B C D E F G]
      relevant = %w[A B C D E]

      expect(described_class.precision_at_k(retrieved, relevant)).to eq(1.0)
    end
  end

  describe '.recall' do
    it 'returns 1.0 when all relevant items are retrieved' do
      retrieved = %w[A B C X Y]
      relevant = %w[A B C]

      expect(described_class.recall(retrieved, relevant)).to eq(1.0)
    end

    it 'returns 0.5 when half the relevant items are found' do
      retrieved = %w[A X Y]
      relevant = %w[A B]

      expect(described_class.recall(retrieved, relevant)).to eq(0.5)
    end

    it 'returns 0.0 when no relevant items are found' do
      retrieved = %w[X Y Z]
      relevant = %w[A B C]

      expect(described_class.recall(retrieved, relevant)).to eq(0.0)
    end

    it 'returns 0.0 for empty relevant set' do
      expect(described_class.recall(%w[A B], [])).to eq(0.0)
    end
  end

  describe '.mrr' do
    it 'returns 1.0 when first result is relevant' do
      retrieved = %w[A B C]
      relevant = %w[A]

      expect(described_class.mrr(retrieved, relevant)).to eq(1.0)
    end

    it 'returns 0.5 when second result is first relevant' do
      retrieved = %w[X A B]
      relevant = %w[A B]

      expect(described_class.mrr(retrieved, relevant)).to eq(0.5)
    end

    it 'returns 1/3 when third result is first relevant' do
      retrieved = %w[X Y A]
      relevant = %w[A]

      expect(described_class.mrr(retrieved, relevant)).to be_within(0.001).of(0.333)
    end

    it 'returns 0.0 when no relevant results found' do
      retrieved = %w[X Y Z]
      relevant = %w[A B]

      expect(described_class.mrr(retrieved, relevant)).to eq(0.0)
    end

    it 'returns 0.0 for empty retrieved' do
      expect(described_class.mrr([], %w[A])).to eq(0.0)
    end
  end

  describe '.context_completeness' do
    it 'returns 1.0 when all required units are present' do
      retrieved = %w[A B C D]
      required = %w[A B]

      expect(described_class.context_completeness(retrieved, required)).to eq(1.0)
    end

    it 'returns 0.5 when half the required units are present' do
      retrieved = %w[A X Y]
      required = %w[A B]

      expect(described_class.context_completeness(retrieved, required)).to eq(0.5)
    end

    it 'returns 0.0 when no required units are present' do
      retrieved = %w[X Y]
      required = %w[A B]

      expect(described_class.context_completeness(retrieved, required)).to eq(0.0)
    end

    it 'returns 1.0 when required is empty' do
      expect(described_class.context_completeness(%w[A B], [])).to eq(1.0)
    end
  end

  describe '.token_efficiency' do
    it 'returns 1.0 when all tokens are relevant' do
      expect(described_class.token_efficiency(1000, 1000)).to eq(1.0)
    end

    it 'returns 0.5 when half the tokens are relevant' do
      expect(described_class.token_efficiency(500, 1000)).to eq(0.5)
    end

    it 'returns 0.0 when no tokens are relevant' do
      expect(described_class.token_efficiency(0, 1000)).to eq(0.0)
    end

    it 'returns 0.0 when total tokens is zero' do
      expect(described_class.token_efficiency(0, 0)).to eq(0.0)
    end

    it 'caps at 1.0 even if relevant exceeds total' do
      expect(described_class.token_efficiency(1500, 1000)).to eq(1.0)
    end
  end
end
