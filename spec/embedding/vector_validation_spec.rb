# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/embedding/provider'

RSpec.describe Woods::Embedding::Provider::VectorValidation do
  def call(vectors, expected_count:, indexes: nil, provider: 'TestProvider')
    described_class.validate!(vectors, expected_count: expected_count, provider: provider, indexes: indexes)
  end

  describe '.validate!' do
    it 'does not raise for a valid single-vector response' do
      expect { call([[0.1, 0.2, 0.3]], expected_count: 1) }.not_to raise_error
    end

    it 'does not raise for a valid batch response with consistent dimensions' do
      expect do
        call([[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]], expected_count: 3)
      end.not_to raise_error
    end

    it 'does not raise for a valid batch with complete, unique OpenAI-style indexes' do
      expect do
        call([[0.1, 0.2], [0.3, 0.4]], expected_count: 2, indexes: [1, 0])
      end.not_to raise_error
    end

    it 'raises a typed error when the response is short (cardinality mismatch)' do
      expect { call([[0.1, 0.2]], expected_count: 3, provider: 'OpenAI') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse) do |error|
          expect(error.message).to include('OpenAI')
          expect(error.message).to include('3')
        end
    end

    it 'raises a typed error when the response is longer than requested' do
      expect { call([[0.1], [0.2], [0.3]], expected_count: 2) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse)
    end

    it 'raises a typed error on a duplicate OpenAI response index' do
      expect { call([[0.1, 0.2], [0.3, 0.4]], expected_count: 2, indexes: [0, 0], provider: 'OpenAI') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /index/i)
    end

    it 'raises a typed error when OpenAI response indexes skip a position' do
      expect { call([[0.1, 0.2], [0.3, 0.4]], expected_count: 2, indexes: [0, 2], provider: 'OpenAI') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /index/i)
    end

    it 'raises a typed error when a vector contains NaN' do
      expect { call([[0.1, Float::NAN, 0.3]], expected_count: 1) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /finite|numeric/i)
    end

    it 'raises a typed error when a vector contains Infinity' do
      expect { call([[0.1, Float::INFINITY]], expected_count: 1) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /finite|numeric/i)
    end

    it 'raises a typed error when a vector contains nil' do
      expect { call([[0.1, nil, 0.3]], expected_count: 1) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /finite|numeric/i)
    end

    it 'raises a typed error when a vector is an empty array' do
      expect { call([[]], expected_count: 1) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /empty/i)
    end

    it 'raises a typed error when a vector is nil instead of an array' do
      expect { call([nil], expected_count: 1) }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse)
    end

    it 'raises a typed error when vectors in a batch have inconsistent dimensions' do
      expect { call([[0.1, 0.2, 0.3], [0.4, 0.5]], expected_count: 2, provider: 'Ollama') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /dimension/i)
    end

    it 'names the provider and batch size in the error message' do
      expect { call([[0.1, 0.2]], expected_count: 5, provider: 'Ollama') }
        .to raise_error(Woods::Embedding::Provider::InvalidEmbeddingResponse, /Ollama.*5|5.*Ollama/)
    end
  end
end
