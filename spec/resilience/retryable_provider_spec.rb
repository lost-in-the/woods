# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/embedding/provider'
require 'codebase_index/resilience/circuit_breaker'
require 'codebase_index/resilience/retryable_provider'

RSpec.describe CodebaseIndex::Resilience::RetryableProvider do
  let(:mock_provider) do
    instance_double(
      CodebaseIndex::Embedding::Provider::Ollama,
      dimensions: 384,
      model_name: 'test-model'
    )
  end

  subject(:retryable) { described_class.new(provider: mock_provider, max_retries: 3) }

  describe '#dimensions' do
    it 'delegates to the wrapped provider' do
      expect(retryable.dimensions).to eq(384)
    end
  end

  describe '#model_name' do
    it 'delegates to the wrapped provider' do
      expect(retryable.model_name).to eq('test-model')
    end
  end

  describe '#embed' do
    context 'when the provider succeeds immediately' do
      before { allow(mock_provider).to receive(:embed).and_return([0.1, 0.2, 0.3]) }

      it 'returns the embedding' do
        expect(retryable.embed('hello')).to eq([0.1, 0.2, 0.3])
      end
    end

    context 'when the provider fails then succeeds' do
      it 'retries and returns the result' do
        call_count = 0
        allow(mock_provider).to receive(:embed) do
          call_count += 1
          raise StandardError, 'transient error' if call_count < 3

          [0.1, 0.2, 0.3]
        end

        # Stub sleep to avoid actual delays
        allow(retryable).to receive(:sleep)

        expect(retryable.embed('hello')).to eq([0.1, 0.2, 0.3])
        expect(call_count).to eq(3)
      end
    end

    context 'when max retries are exceeded' do
      before do
        allow(mock_provider).to receive(:embed).and_raise(StandardError, 'persistent error')
        allow(retryable).to receive(:sleep)
      end

      it 'raises the last error after exhausting retries' do
        expect { retryable.embed('hello') }.to raise_error(StandardError, 'persistent error')
      end
    end

    context 'with exponential backoff' do
      before do
        call_count = 0
        allow(mock_provider).to receive(:embed) do
          call_count += 1
          raise StandardError, 'fail' if call_count < 3

          [0.1]
        end
      end

      it 'sleeps with exponential backoff between retries' do
        allow(retryable).to receive(:sleep)

        retryable.embed('hello')

        expect(retryable).to have_received(:sleep).with(0.2).ordered  # 2^1 * 0.1
        expect(retryable).to have_received(:sleep).with(0.4).ordered  # 2^2 * 0.1
      end
    end
  end

  describe '#embed_batch' do
    context 'when the provider succeeds immediately' do
      before { allow(mock_provider).to receive(:embed_batch).and_return([[0.1], [0.2]]) }

      it 'returns the embeddings' do
        expect(retryable.embed_batch(%w[a b])).to eq([[0.1], [0.2]])
      end
    end

    context 'when the provider fails then succeeds' do
      it 'retries and returns the result' do
        call_count = 0
        allow(mock_provider).to receive(:embed_batch) do
          call_count += 1
          raise StandardError, 'transient' if call_count < 2

          [[0.1], [0.2]]
        end

        allow(retryable).to receive(:sleep)

        expect(retryable.embed_batch(%w[a b])).to eq([[0.1], [0.2]])
        expect(call_count).to eq(2)
      end
    end
  end

  describe 'circuit breaker integration' do
    let(:circuit_breaker) { CodebaseIndex::Resilience::CircuitBreaker.new(threshold: 2, reset_timeout: 0.1) }

    subject(:retryable_with_cb) do
      described_class.new(provider: mock_provider, max_retries: 3, circuit_breaker: circuit_breaker)
    end

    context 'when circuit breaker is open' do
      before do
        allow(mock_provider).to receive(:embed).and_raise(StandardError, 'fail')
        allow(retryable_with_cb).to receive(:sleep)

        # Trip the circuit breaker
        begin
          retryable_with_cb.embed('test')
        rescue StandardError
          nil
        end
      end

      it 'raises CircuitOpenError without retrying' do
        expect do
          retryable_with_cb.embed('test')
        end.to raise_error(CodebaseIndex::Resilience::CircuitOpenError)
      end
    end

    context 'when provider succeeds through circuit breaker' do
      before { allow(mock_provider).to receive(:embed).and_return([0.5]) }

      it 'returns the result' do
        expect(retryable_with_cb.embed('hello')).to eq([0.5])
      end
    end
  end

  describe 'Interface compliance' do
    it 'includes the Provider::Interface module' do
      expect(described_class.ancestors).to include(CodebaseIndex::Embedding::Provider::Interface)
    end
  end
end
