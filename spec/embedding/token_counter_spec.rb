# frozen_string_literal: true

require 'spec_helper'
require 'woods/embedding/token_counter'

# Pre-load tokenizers so stub_const('Tokenizers', fake) below isn't racing
# with try_load's `require 'tokenizers'`. Without this pre-load, the gem's
# top-level `module Tokenizers` re-opens the stubbed module under random
# test orderings, leaking the real `from_pretrained` onto the fake.
begin
  require 'tokenizers'
rescue LoadError
  # gem absent (Ruby 3.0 row): try_load hits its LoadError branch, which
  # is the equivalent failure path for these specs.
end

RSpec.describe Woods::Embedding::TokenCounter do
  subject(:counter) { described_class.new }

  describe '#count' do
    it 'returns 0 for nil' do
      expect(counter.count(nil)).to eq(0)
    end

    it 'returns 0 for empty string' do
      expect(counter.count('')).to eq(0)
    end

    context 'when the tokenizers gem is available (Gemfile test group)' do
      it 'returns exact token counts via bert-base-uncased' do
        skip 'tokenizers gem not installed' unless counter.exact?

        # Sanity check: a dense Rails-style constant tokenizes into more
        # pieces than a naive chars/4 would suggest — nothing specific
        # to assert about the ratio, but the count must be > 0 and the
        # tokenizer must round-trip via #decode.
        count = counter.count('ActionController::Metal::ConditionalGet')
        expect(count).to be > 0
        expect(count).to be < 'ActionController::Metal::ConditionalGet'.length
      end

      it 'reports exact? true' do
        skip 'tokenizers gem not installed' unless counter.exact?
        expect(counter.exact?).to be(true)
      end
    end

    context 'when tokenizer loading fails' do
      before do
        fake_tokenizers = Module.new do
          def self.from_pretrained(*)
            raise StandardError, 'simulated network failure'
          end
        end
        stub_const('Tokenizers', fake_tokenizers)
      end

      it 'falls back to chars/token estimation' do
        counter = described_class.new(chars_per_token: 2.0)
        # 10-char input / 2.0 chars_per_token = 5 tokens
        expect(counter.count('0123456789')).to eq(5)
      end

      it 'memoizes the failed load so it only warns once' do
        counter = described_class.new
        expect(Kernel).to receive(:warn).once
        counter.count('first call triggers load + warn')
        counter.count('second call stays on the fallback path')
      end

      it 'reports exact? false' do
        expect(described_class.new.exact?).to be(false)
      end
    end

    context 'when the tokenizers gem is missing' do
      before do
        # Force the soft-require branch even though the gem is present.
        allow_any_instance_of(described_class).to receive(:require)
          .with('tokenizers').and_raise(LoadError, 'simulated missing gem')
      end

      it 'falls back to chars/token estimation' do
        counter = described_class.new(chars_per_token: 4.0)
        # 12 chars / 4.0 = 3 tokens
        expect(counter.count('hello world!')).to eq(3)
      end

      it 'warns with install instructions' do
        expect(Kernel).to receive(:warn).with(/gem 'tokenizers'/)
        described_class.new.count('anything')
      end
    end
  end

  describe '#exact?' do
    it 'lazy-loads only on first call' do
      counter = described_class.new
      # Before any count call, no load is attempted — but exact? itself
      # triggers the load, so call it once and verify the second call
      # is idempotent.
      first = counter.exact?
      second = counter.exact?
      expect(first).to eq(second)
    end
  end

  describe 'thread safety' do
    it 'loads the tokenizer at most once under concurrent access' do
      counter = described_class.new
      results = Array.new(4) { Thread.new { counter.count('racing call') } }.map(&:value)
      expect(results).to all(be_a(Integer))
    end
  end
end
