# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/resilience/circuit_breaker'

RSpec.describe Woods::Resilience::CircuitBreaker, 'cyclic / re-entrant scenarios' do
  # State transitions remain correct when the same call path cycles back
  # through the same breaker (e.g., A calls B calls A).
  # CLAUDE.md: "state is per-instance, not global"

  describe 'state transitions remain correct under re-entrant calls' do
    subject(:breaker) { described_class.new(threshold: 3, reset_timeout: 0.05) }

    it 'state is per-instance — two independent breakers track failures separately' do
      breaker_a = described_class.new(threshold: 2, reset_timeout: 60)
      breaker_b = described_class.new(threshold: 2, reset_timeout: 60)

      # Exhaust breaker_a
      2.times { breaker_a.call { raise StandardError, 'fail' } rescue nil } # rubocop:disable Style/RescueModifier

      expect(breaker_a.state).to eq(:open)
      expect(breaker_b.state).to eq(:closed)
    end

    it 'failures are counted per instance — exhausting one does not affect another' do
      shared_threshold = 3
      breaker_a = described_class.new(threshold: shared_threshold, reset_timeout: 60)
      breaker_b = described_class.new(threshold: shared_threshold, reset_timeout: 60)

      # Fail breaker_a to threshold
      shared_threshold.times { breaker_a.call { raise StandardError } rescue nil } # rubocop:disable Style/RescueModifier

      # breaker_b should still allow calls
      expect { breaker_b.call { 42 } }.not_to raise_error
      expect(breaker_b.state).to eq(:closed)
    end

    it 'closed → open → half_open → closed cycle works correctly' do
      # Drive to :open
      3.times { breaker.call { raise StandardError, 'fail' } rescue nil } # rubocop:disable Style/RescueModifier
      expect(breaker.state).to eq(:open)

      # Real sleep past reset_timeout (0.05s) — breaker uses a monotonic clock.
      sleep 0.08
      breaker.call { 'recovered' }

      expect(breaker.state).to eq(:closed)
    end

    it 'half_open probe failure returns to :open with a fresh cooldown' do
      # Drive to :open
      3.times { breaker.call { raise StandardError } rescue nil } # rubocop:disable Style/RescueModifier

      sleep 0.08 # past reset_timeout 0.05

      # half_open probe fails
      breaker.call { raise StandardError, 'still broken' } rescue nil # rubocop:disable Style/RescueModifier
      expect(breaker.state).to eq(:open)

      # Fresh cooldown: calls within the new window are rejected
      expect { breaker.call { 'attempt' } }.to raise_error(Woods::Resilience::CircuitOpenError)
    end

    it 'a cyclic call path does not corrupt failure counts' do
      # Simulate A → B → A by re-entering the same breaker from within its own block.
      # The breaker uses a non-reentrant Mutex; the outer block executes outside the mutex,
      # so re-entering via an inner call uses a separate phase-2 execution — this should work
      # without deadlock, and failures count correctly.
      inner_call_count = 0

      breaker = described_class.new(threshold: 5, reset_timeout: 60)

      # First outer call succeeds, triggering an inner call that also succeeds
      breaker.call do
        inner_call_count += 1
        breaker.call { inner_call_count += 1 } # re-entrant — no deadlock expected
      end

      expect(inner_call_count).to eq(2)
      expect(breaker.state).to eq(:closed)
    end

    it 'half_open succeeds then re-entering does not re-open the circuit' do
      3.times { breaker.call { raise StandardError } rescue nil } # rubocop:disable Style/RescueModifier

      sleep 0.08 # past reset_timeout 0.05

      # Successful half-open probe — resets state
      breaker.call { 'probe ok' }
      expect(breaker.state).to eq(:closed)

      # A single subsequent failure should not open (threshold is 3, count was reset)
      breaker.call { raise StandardError } rescue nil # rubocop:disable Style/RescueModifier
      expect(breaker.state).to eq(:closed)
    end
  end
end
