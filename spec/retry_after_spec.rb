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

  # #217 / B-104. The header is server-controlled and nothing stops it saying
  # `86400`. An export client that slept for exactly as long as it was told
  # would sit in `sleep` for a day, so a buggy or hostile 429 could park a sync
  # indefinitely. The embedding providers already capped at 120s (#188); the
  # cap now lives here so every caller gets it.
  describe 'capping' do
    it 'caps an absurd delta-seconds value at MAX_SECONDS' do
      expect(described_class.seconds('86400', fallback: 1)).to eq(described_class::MAX_SECONDS)
    end

    it 'caps an absurd HTTP-date value' do
      now = Time.utc(2026, 1, 1, 0, 0, 0)
      next_week = (now + (7 * 24 * 60 * 60)).httpdate

      expect(described_class.seconds(next_week, fallback: 1, now: now))
        .to eq(described_class::MAX_SECONDS)
    end

    it 'leaves a reasonable value untouched' do
      expect(described_class.seconds('30', fallback: 1)).to eq(30.0)
    end

    it 'caps the fallback too, so a caller cannot smuggle a huge wait past it' do
      expect(described_class.seconds(nil, fallback: 100_000)).to eq(described_class::MAX_SECONDS)
    end

    it 'honours the header uncapped when explicitly asked' do
      expect(described_class.seconds('86400', fallback: 1, max: Float::INFINITY)).to eq(86_400.0)
    end

    it 'exposes the uncapped value via raw_seconds' do
      expect(described_class.raw_seconds('86400', fallback: 1)).to eq(86_400.0)
    end
  end
end
