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

  describe 'HTTP status classification (#188)' do
    def request_error(status, retry_after: nil)
      Woods::Embedding::Provider::RequestError.new(
        "API error: #{status}", http_status: status, retry_after: retry_after
      )
    end

    context 'with a retryable 429 that clears after two attempts' do
      let(:provider) do
        recording_provider_class.new(
          embed_results: [request_error(429), request_error(429), [0.1, 0.2]]
        )
      end

      it 'retries through the rate limit and completes' do
        record_sleep_on(retryable)

        expect(retryable.embed('hello')).to eq([0.1, 0.2])
        expect(provider.embed_calls).to eq(3)
      end
    end

    context 'with a retryable 503' do
      let(:provider) do
        recording_provider_class.new(embed_results: [request_error(503), [0.1]])
      end

      it 'retries server errors' do
        record_sleep_on(retryable)

        expect(retryable.embed('hello')).to eq([0.1])
        expect(provider.embed_calls).to eq(2)
      end
    end

    context 'with a non-retryable 401 (bad credentials)' do
      let(:provider) do
        recording_provider_class.new(
          embed_results: [request_error(401), [0.1]]
        )
      end

      it 'propagates immediately without retrying or sleeping' do
        delays = record_sleep_on(retryable)

        expect { retryable.embed('hello') }
          .to raise_error(Woods::Embedding::Provider::RequestError, /401/)
        expect(provider.embed_calls).to eq(1)
        expect(delays).to be_empty
      end
    end

    context 'with a non-retryable 400 (bad request)' do
      let(:provider) do
        recording_provider_class.new(embed_results: [request_error(400)])
      end

      it 'propagates immediately without burning the retry budget' do
        record_sleep_on(retryable)

        expect { retryable.embed('hello') }
          .to raise_error(Woods::Embedding::Provider::RequestError, /400/)
        expect(provider.embed_calls).to eq(1)
      end
    end

    context 'with a status-less error' do
      let(:provider) do
        recording_provider_class.new(
          embed_results: [Woods::Error.new('connection reset'), [0.1]]
        )
      end

      it 'keeps the historical retry-everything behavior' do
        record_sleep_on(retryable)

        expect(retryable.embed('hello')).to eq([0.1])
        expect(provider.embed_calls).to eq(2)
      end
    end

    context 'on embed_batch' do
      let(:provider) do
        recording_provider_class.new(embed_batch_results: [request_error(401)])
      end

      it 'classifies the same way as embed' do
        record_sleep_on(retryable)

        expect { retryable.embed_batch(%w[a b]) }
          .to raise_error(Woods::Embedding::Provider::RequestError, /401/)
        expect(provider.embed_batch_calls).to eq(1)
      end
    end
  end

  describe 'Retry-After honoring (#188)' do
    def rate_limited(retry_after)
      Woods::Embedding::Provider::RequestError.new(
        'API error: 429', http_status: 429, retry_after: retry_after
      )
    end

    context 'with a delta-seconds Retry-After' do
      let(:provider) do
        recording_provider_class.new(embed_results: [rate_limited('7'), [0.1]])
      end

      it 'sleeps for the server-requested duration instead of local backoff' do
        delays = record_sleep_on(retryable)

        retryable.embed('hello')

        expect(delays).to eq([7.0])
      end
    end

    context 'with an absurdly large Retry-After' do
      let(:provider) do
        recording_provider_class.new(embed_results: [rate_limited('3600'), [0.1]])
      end

      it 'caps the wait at MAX_RETRY_AFTER_SECONDS' do
        delays = record_sleep_on(retryable)

        retryable.embed('hello')

        expect(delays).to eq([Woods::Resilience::RetryableProvider::MAX_RETRY_AFTER_SECONDS])
      end
    end

    context 'with no Retry-After on the error' do
      let(:provider) do
        recording_provider_class.new(embed_results: [rate_limited(nil), [0.1]])
      end

      it 'falls back to full-jitter exponential backoff' do
        delays = record_sleep_on(retryable)
        allow(retryable).to receive(:rand).and_return(1.0)

        retryable.embed('hello')

        # attempt 1 ceiling: BACKOFF_BASE * 2 = 0.2
        expect(delays).to eq([0.2])
      end
    end

    context 'with an unparseable Retry-After' do
      let(:provider) do
        recording_provider_class.new(embed_results: [rate_limited('soon-ish'), [0.1]])
      end

      it 'falls back to the local backoff value' do
        delays = record_sleep_on(retryable)
        allow(retryable).to receive(:rand).and_return(1.0)

        retryable.embed('hello')

        expect(delays).to eq([0.2])
      end
    end
  end

  describe '#provider / #circuit_breaker readers' do
    it 'exposes the wrapped provider' do
      expect(retryable.provider).to be(provider)
    end

    it 'exposes the configured circuit breaker' do
      breaker = Woods::Resilience::CircuitBreaker.new
      wrapped = described_class.new(provider: provider, circuit_breaker: breaker)
      expect(wrapped.circuit_breaker).to be(breaker)
    end

    it 'returns nil for circuit_breaker when none was configured' do
      expect(retryable.circuit_breaker).to be_nil
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

  describe '#max_input_tokens' do
    it 'delegates to a wrapped provider that defines it' do
      provider = recording_provider_class.new
      def provider.max_input_tokens
        4096
      end
      retryable = described_class.new(provider: provider)
      expect(retryable.max_input_tokens).to eq(4096)
    end

    # B-108: Provider::Interface *defines* #max_input_tokens (as a
    # NotImplementedError stub), so respond_to?(:max_input_tokens) answers
    # true for a provider that merely includes the interface without
    # overriding it — the raise reached the caller instead of nil.
    it 'returns nil for a wrapped provider that only inherits the interface stub' do
      provider_class = Class.new(recording_provider_class) do
        include Woods::Embedding::Provider::Interface
      end
      retryable = described_class.new(provider: provider_class.new)
      expect(retryable.max_input_tokens).to be_nil
    end
  end
end
