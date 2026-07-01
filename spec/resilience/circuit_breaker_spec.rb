# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/resilience/circuit_breaker'

RSpec.describe Woods::Resilience::CircuitBreaker do
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
        end.to raise_error(Woods::Resilience::CircuitOpenError)
        expect(block_called).to be false
      end

      it 'transitions to half_open after the reset timeout elapses' do
        sleep 0.4 # reset_timeout is 0.1 — large margin so CI jitter can't flake

        # The next call attempt will transition to half_open then close on success
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
        sleep 0.4 # reset_timeout is 0.1 — large margin so CI jitter can't flake
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

      it 'admits only a single probe at a time, rejecting concurrent calls' do
        probe_started = Queue.new
        release_probe = Queue.new
        rejected = nil

        probe = Thread.new do
          breaker.call do
            probe_started << true
            release_probe.pop # hold the half_open probe in flight
            'recovered'
          end
        end

        probe_started.pop # ensure the probe is executing (state is half_open)
        begin
          breaker.call { 'second probe' }
        rescue Woods::Resilience::CircuitOpenError => e
          rejected = e
        end

        release_probe << true
        probe.join

        expect(rejected).to be_a(Woods::Resilience::CircuitOpenError)
        expect(breaker.state).to eq(:closed) # the single probe succeeded and closed the circuit
      end
    end

    context 'when half_open with a success_threshold > 1' do
      subject(:breaker) { described_class.new(threshold: 2, reset_timeout: 0.1, success_threshold: 2) }

      before do
        2.times do
          breaker.call { raise StandardError, 'fail' }
        rescue StandardError
          nil
        end
        sleep 0.3
      end

      it 'requires the configured number of consecutive successful probes to close' do
        breaker.call { 'probe 1' }
        expect(breaker.state).to eq(:half_open) # not closed after a single success

        breaker.call { 'probe 2' }
        expect(breaker.state).to eq(:closed)
      end

      it 'reopens and resets progress if a probe fails mid-recovery' do
        breaker.call { 'probe 1' }
        expect(breaker.state).to eq(:half_open)

        begin
          breaker.call { raise StandardError, 'regressed' }
        rescue StandardError
          nil
        end
        expect(breaker.state).to eq(:open)
      end
    end
  end

  describe 'CircuitOpenError' do
    it 'is a subclass of Woods::Error' do
      expect(Woods::Resilience::CircuitOpenError).to be < Woods::Error
    end
  end

  describe 'with default parameters' do
    it 'accepts default threshold and reset_timeout' do
      default_breaker = described_class.new
      expect(default_breaker.state).to eq(:closed)
    end
  end

  describe 'thread safety' do
    it 'correctly counts failures across threads' do
      breaker = described_class.new(threshold: 100, reset_timeout: 60)
      threads = 20.times.map do
        Thread.new do
          5.times do
            breaker.call { raise StandardError, 'fail' }
          rescue StandardError
            nil
          end
        end
      end
      threads.each(&:join)

      # With proper synchronization, all 100 failures should be counted
      # and the circuit should be open
      expect(breaker.state).to eq(:open)
    end

    it 'does not hold the mutex during block execution (calls overlap)' do
      breaker = described_class.new(threshold: 5, reset_timeout: 60)
      sleep_duration = 0.1
      thread_count = 3

      start_time = Time.now
      threads = thread_count.times.map do
        Thread.new do
          breaker.call { sleep(sleep_duration) }
        end
      end
      threads.each(&:join)
      elapsed = Time.now - start_time

      # If mutex were held during block.call, total time would be ~3x sleep_duration.
      # With mutex released, all 3 threads sleep concurrently, so total < 2x.
      expect(elapsed).to be < (sleep_duration * 2)
    end
  end
end
