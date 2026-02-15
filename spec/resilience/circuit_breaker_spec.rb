# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/resilience/circuit_breaker'

RSpec.describe CodebaseIndex::Resilience::CircuitBreaker do
  subject(:breaker) { described_class.new(threshold: 3, reset_timeout: 0.1) }

  describe '#initialize' do
    it 'starts in the closed state' do
      expect(breaker.state).to eq(:closed)
    end
  end

  describe '#call' do
    context 'when closed' do
      it 'passes through successful calls' do
        result = breaker.call { 42 }
        expect(result).to eq(42)
      end

      it 'passes through the block return value' do
        result = breaker.call { 'hello' }
        expect(result).to eq('hello')
      end

      it 're-raises errors from the block' do
        expect { breaker.call { raise StandardError, 'boom' } }.to raise_error(StandardError, 'boom')
      end

      it 'remains closed after fewer failures than threshold' do
        (3 - 1).times do
          breaker.call { raise StandardError, 'fail' }
        rescue StandardError
          nil
        end

        expect(breaker.state).to eq(:closed)
      end

      it 'opens after reaching the failure threshold' do
        3.times do
          breaker.call { raise StandardError, 'fail' }
        rescue StandardError
          nil
        end

        expect(breaker.state).to eq(:open)
      end

      it 'resets failure count on success' do
        2.times do
          breaker.call { raise StandardError, 'fail' }
        rescue StandardError
          nil
        end

        breaker.call { 'success' }

        # Should not open after one more failure (count was reset)
        begin
          breaker.call { raise StandardError, 'fail' }
        rescue StandardError
          nil
        end

        expect(breaker.state).to eq(:closed)
      end
    end

    context 'when open' do
      before do
        3.times do
          breaker.call { raise StandardError, 'fail' }
        rescue StandardError
          nil
        end
      end

      it 'raises CircuitOpenError without executing the block' do
        block_called = false
        expect do
          breaker.call { block_called = true }
        end.to raise_error(CodebaseIndex::Resilience::CircuitOpenError)
        expect(block_called).to be false
      end

      it 'transitions to half_open after the reset timeout elapses' do
        sleep(0.15)

        # The next call attempt will transition to half_open
        breaker.call { 'recovered' }
        expect(breaker.state).to eq(:closed)
      end
    end

    context 'when half_open' do
      before do
        3.times do
          breaker.call { raise StandardError, 'fail' }
        rescue StandardError
          nil
        end
        sleep(0.15)
      end

      it 'closes on successful call' do
        breaker.call { 'success' }
        expect(breaker.state).to eq(:closed)
      end

      it 're-opens on failed call' do
        begin
          breaker.call { raise StandardError, 'still broken' }
        rescue StandardError
          nil
        end

        expect(breaker.state).to eq(:open)
      end
    end
  end

  describe 'CircuitOpenError' do
    it 'is a subclass of CodebaseIndex::Error' do
      expect(CodebaseIndex::Resilience::CircuitOpenError).to be < CodebaseIndex::Error
    end
  end

  describe 'with default parameters' do
    it 'accepts default threshold and reset_timeout' do
      default_breaker = described_class.new
      expect(default_breaker.state).to eq(:closed)
    end
  end
end
