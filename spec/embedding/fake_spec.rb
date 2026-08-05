# frozen_string_literal: true

require 'spec_helper'
require 'woods/embedding/fake'

# Promoted from spec/support in #178 so `embedding_provider = :fake` works
# outside the suite (CI, sandboxes, offline hosts). The vector-quality
# behaviour (normalization, similarity ordering, call tracking) is also
# exercised end-to-end in spec/integration/chunking_embedding_pipeline_spec.rb.
RSpec.describe Woods::Embedding::Provider::Fake do
  subject(:provider) { described_class.new(dims: 32) }

  describe 'provider interface' do
    it 'implements the full embedding provider contract' do
      expect(provider).to respond_to(:embed, :embed_batch, :dimensions, :model_name, :max_input_tokens)
    end

    it 'reports its configured dimensionality' do
      expect(provider.dimensions).to eq(32)
    end

    it 'defaults to DEFAULT_DIMS' do
      expect(described_class.new.dimensions).to eq(described_class::DEFAULT_DIMS)
    end

    it 'reports an unmistakably fake model name by default' do
      expect(provider.model_name).to eq(described_class::DEFAULT_MODEL_NAME)
    end

    it 'accepts a model name (the MCP woods.json restore path passes one)' do
      expect(described_class.new(model: 'from-snapshot').model_name).to eq('from-snapshot')
    end

    it 'advertises no input budget so the indexer skips auto-chunking' do
      expect(provider.max_input_tokens).to be_nil
    end

    it 'rejects a non-positive dimensionality' do
      expect { described_class.new(dims: 0) }
        .to raise_error(ArgumentError, /dims must be positive/)
    end
  end

  describe 'determinism' do
    it 'returns identical vectors for identical input across instances' do
      other = described_class.new(dims: 32)

      expect(provider.embed('has_many :posts')).to eq(other.embed('has_many :posts'))
    end

    it 'returns one vector per input in embed_batch, matching single embeds' do
      batch = provider.embed_batch(['first text', 'second text'])

      expect(batch.length).to eq(2)
      expect(batch.first).to eq(described_class.new(dims: 32).embed('first text'))
    end
  end

  describe 'vector properties' do
    it 'L2-normalizes every non-empty embedding' do
      vec = provider.embed('class User < ApplicationRecord')

      expect(Math.sqrt(vec.sum { |v| v**2 })).to be_within(0.001).of(1.0)
    end

    # Unlike the network providers, which raise ArgumentError on empty
    # input to pre-empt a provider-side 400, the fake accepts anything —
    # it exists so pipelines run offline, not to reproduce API errors.
    it 'returns a zero vector for input with no words instead of raising' do
      expect(provider.embed('')).to eq(Array.new(32, 0.0))
    end

    it 'scores vocabulary-sharing texts closer than unrelated texts' do
      user = provider.embed('class User has_many posts')
      post = provider.embed('class Post belongs_to user')
      unrelated = provider.embed('redis cache warmer ping connection')

      expect(cosine(user, post)).to be > cosine(user, unrelated)
    end
  end

  describe '#calls' do
    it 'records every embed and embed_batch invocation for inspection' do
      provider.embed('one')
      provider.embed_batch(%w[two three])

      expect(provider.calls).to eq([['one'], %w[two three]])
    end
  end

  def cosine(vec_a, vec_b)
    vec_a.zip(vec_b).sum { |a, b| a * b }
  end
end
