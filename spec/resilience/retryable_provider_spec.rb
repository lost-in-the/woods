# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/embedding/provider'
require 'woods/resilience/circuit_breaker'
require 'woods/resilience/retryable_provider'

RSpec.describe Woods::Resilience::RetryableProvider do
  # Hand-rolled provider stub. Callers configure behavior by supplying
  # sequences of results (values or exceptions); the stub replays them.
  let(:recording_provider_class) do
    Class.new do
      attr_reader :embed_calls, :embed_batch_calls, :dimensions, :model_name

      def initialize(embed_results: [], embed_batch_results: [], dimensions: 384, model_name: 'test-model')
        @embed_results = embed_results.dup
        @embed_batch_results = embed_batch_results.dup
        @dimensions = dimensions
        @model_name = model_name
        @embed_calls = 0
        @embed_batch_calls = 0
      end

      def embed(_text)
        @embed_calls += 1
        dispense(@embed_results)
      end

      def embed_batch(_texts)
        @embed_batch_calls += 1
        dispense(@embed_batch_results)
      end

      private

      def dispense(queue)
        result = queue.shift
        raise result if result.is_a?(Exception)

        result
      end
    end
  end

  # Replace sleep with a recorder on a specific retryable instance. Returns the
  # array that captures actual delay durations, so specs assert against real
  # backoff values rather than message call history.
  def record_sleep_on(retryable)
    delays = []
    retryable.define_singleton_method(:sleep) { |d| delays << d }
    delays
  end

  let(:provider) { recording_provider_class.new(embed_results: [[0.1, 0.2, 0.3]]) }

  subject(:retryable) { described_class.new(provider: provider, max_retries: 3) }

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
      it 'returns the embedding without retrying' do
        expect(retryable.embed('hello')).to eq([0.1, 0.2, 0.3])
        expect(provider.embed_calls).to eq(1)
      end
    end

    context 'when the provider fails then succeeds' do
      let(:provider) do
        recording_provider_class.new(
          embed_results: [
            StandardError.new('transient error'),
            StandardError.new('transient error'),
            [0.1, 0.2, 0.3]
          ]
        )
      end

      it 'retries and eventually returns the embedding' do
        record_sleep_on(retryable)

        expect(retryable.embed('hello')).to eq([0.1, 0.2, 0.3])
        expect(provider.embed_calls).to eq(3)
      end
    end

    context 'when max retries are exceeded' do
      let(:provider) do
        recording_provider_class.new(
          embed_results: Array.new(10) { StandardError.new('persistent error') }
        )
      end

      it 'raises the last error after exhausting retries' do
        record_sleep_on(retryable)

        expect { retryable.embed('hello') }.to raise_error(StandardError, 'persistent error')
      end

      it 'attempts max_retries + 1 times in total' do
        record_sleep_on(retryable)

        begin
          retryable.embed('hello')
        rescue StandardError
          # expected
        end

        expect(provider.embed_calls).to eq(4) # initial + 3 retries
      end
    end

    context 'with exponential backoff' do
      let(:provider) do
        recording_provider_class.new(
          embed_results: [
            StandardError.new('fail'),
            StandardError.new('fail'),
            [0.1]
          ]
        )
      end

      it 'uses exponentially growing delay ceilings with full jitter, capped' do
        delays = record_sleep_on(retryable)

        # Force jitter to its maximum so the assertion is deterministic —
        # sleep ≈ ceiling where ceiling = min(BACKOFF_BASE * 2**attempt, 30).
        allow(retryable).to receive(:rand).and_return(1.0)

        retryable.embed('hello')

        # 2 retries observed with maximum jitter hit each time:
        #   attempt 1: 0.1 * 2 = 0.2
        #   attempt 2: 0.1 * 4 = 0.4
        expect(delays).to eq([0.2, 0.4])
      end

      it 'caps individual delays at MAX_BACKOFF_SECONDS regardless of attempt' do
        # Synthetic very-high attempt via direct helper — exercises the
        # min(..., 30) cap. rand forced to 1.0 to eliminate randomness.
        allow(retryable).to receive(:rand).and_return(1.0)
        expect(retryable.send(:backoff_seconds, 20)).to be <= Woods::Resilience::RetryableProvider::MAX_BACKOFF_SECONDS
      end

      it 'applies jitter — delays are bounded above by the ceiling' do
        delays = record_sleep_on(retryable)
        allow(retryable).to receive(:rand).and_return(0.5)

        retryable.embed('hello')

        expect(delays[0]).to be <= 0.2
        expect(delays[1]).to be <= 0.4
      end
    end
  end

  describe '#embed_batch' do
    context 'when the provider succeeds immediately' do
      let(:provider) { recording_provider_class.new(embed_batch_results: [[[0.1], [0.2]]]) }

      it 'returns the embeddings' do
        expect(retryable.embed_batch(%w[a b])).to eq([[0.1], [0.2]])
        expect(provider.embed_batch_calls).to eq(1)
      end
    end

    context 'when the provider fails then succeeds' do
      let(:provider) do
        recording_provider_class.new(
          embed_batch_results: [StandardError.new('transient'), [[0.1], [0.2]]]
        )
      end

      it 'retries and returns the result' do
        record_sleep_on(retryable)

        expect(retryable.embed_batch(%w[a b])).to eq([[0.1], [0.2]])
        expect(provider.embed_batch_calls).to eq(2)
      end
    end
  end

  describe 'circuit breaker integration' do
    let(:circuit_breaker) { Woods::Resilience::CircuitBreaker.new(threshold: 2, reset_timeout: 0.1) }
    let(:provider) do
      recording_provider_class.new(
        embed_results: Array.new(10) { StandardError.new('fail') }
      )
    end

    subject(:retryable_with_cb) do
      described_class.new(provider: provider, max_retries: 3, circuit_breaker: circuit_breaker)
    end

    context 'when circuit breaker is open' do
      before do
        record_sleep_on(retryable_with_cb)

        # Trip the circuit breaker by exhausting retries once
        begin
          retryable_with_cb.embed('test')
        rescue StandardError
          nil
        end
      end

      it 'raises CircuitOpenError without invoking the provider' do
        calls_before = provider.embed_calls

        expect do
          retryable_with_cb.embed('test')
        end.to raise_error(Woods::Resilience::CircuitOpenError)

        expect(provider.embed_calls).to eq(calls_before)
      end
    end

    context 'when provider succeeds through circuit breaker' do
      let(:provider) { recording_provider_class.new(embed_results: [[0.5]]) }

      it 'returns the result' do
        expect(retryable_with_cb.embed('hello')).to eq([0.5])
      end
    end
  end

  describe 'Interface compliance' do
    it 'includes the Provider::Interface module' do
      expect(described_class.ancestors).to include(Woods::Embedding::Provider::Interface)
    end
  end
end
