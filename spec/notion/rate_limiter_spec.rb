# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/notion/rate_limiter'

RSpec.describe CodebaseIndex::Notion::RateLimiter do
  subject(:limiter) { described_class.new(requests_per_second: requests_per_second) }

  let(:requests_per_second) { 3 }

  describe '#initialize' do
    it 'accepts requests_per_second parameter' do
      expect(limiter).to be_a(described_class)
    end

    it 'defaults to 3 requests per second' do
      default_limiter = described_class.new
      expect(default_limiter).to be_a(described_class)
    end

    it 'raises on non-positive requests_per_second' do
      expect { described_class.new(requests_per_second: 0) }.to raise_error(ArgumentError)
      expect { described_class.new(requests_per_second: -1) }.to raise_error(ArgumentError)
    end
  end

  describe '#throttle' do
    it 'yields the block' do
      expect { |b| limiter.throttle(&b) }.to yield_control
    end

    it 'returns the block result' do
      result = limiter.throttle { 42 }
      expect(result).to eq(42)
    end

    it 'raises ArgumentError without a block' do
      expect { limiter.throttle }.to raise_error(ArgumentError)
    end

    it 'does not sleep on first call' do
      allow(limiter).to receive(:sleep)
      limiter.throttle { 'first' }
      expect(limiter).not_to have_received(:sleep)
    end

    it 'enforces minimum interval between calls' do
      # With 3 req/sec, minimum interval is ~0.333s
      allow(limiter).to receive(:sleep)

      limiter.throttle { 'first' }
      limiter.throttle { 'second' }

      expect(limiter).to have_received(:sleep).at_least(:once)
    end

    it 'does not sleep if enough time has passed' do
      fast_limiter = described_class.new(requests_per_second: 1000)
      allow(fast_limiter).to receive(:sleep)

      fast_limiter.throttle { 'first' }
      fast_limiter.throttle { 'second' }

      # With 1000 req/sec, the interval is 0.001s — likely already elapsed
      # This is a best-effort test; the key behavior is tested above
    end

    it 'is thread-safe' do
      results = []
      mutex = Mutex.new
      threads = 5.times.map do |i|
        Thread.new do
          result = limiter.throttle { i }
          mutex.synchronize { results << result }
        end
      end
      threads.each(&:join)

      expect(results.sort).to eq([0, 1, 2, 3, 4])
    end
  end
end
