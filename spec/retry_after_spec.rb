# frozen_string_literal: true

require 'spec_helper'
require 'woods/retry_after'

RSpec.describe Woods::RetryAfter do
  describe '.seconds' do
    it 'parses the delta-seconds (integer) form' do
      expect(described_class.seconds('30', fallback: 5)).to eq(30.0)
    end

    it 'returns the fallback when the header is absent' do
      expect(described_class.seconds(nil, fallback: 7)).to eq(7.0)
    end

    it 'returns the fallback when the header is blank' do
      expect(described_class.seconds('   ', fallback: 3)).to eq(3.0)
    end

    it 'parses the HTTP-date form as seconds until that instant' do
      now = Time.utc(2026, 7, 1, 12, 0, 0)
      future = (now + 45).httpdate # RFC 9110 HTTP-date, 45s ahead

      expect(described_class.seconds(future, fallback: 5, now: now)).to be_within(0.001).of(45.0)
    end

    it 'never returns a negative wait for an HTTP-date in the past' do
      now = Time.utc(2026, 7, 1, 12, 0, 0)
      past = (now - 60).httpdate

      expect(described_class.seconds(past, fallback: 5, now: now)).to eq(0.0)
    end

    it 'does NOT collapse an HTTP-date to 0.0 the way .to_f would' do
      now = Time.utc(2026, 7, 1, 12, 0, 0)
      future = (now + 120).httpdate

      # The bug being fixed: `future.to_f` == 0.0.
      expect(future.to_f).to eq(0.0)
      expect(described_class.seconds(future, fallback: 5, now: now)).to be > 0
    end

    it 'falls back when the header is neither an integer nor a valid HTTP-date' do
      expect(described_class.seconds('soon-ish', fallback: 9)).to eq(9.0)
    end
  end
end
