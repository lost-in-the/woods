# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/coordination/pipeline_lock'
require 'codebase_index/resilience/circuit_breaker'
require 'codebase_index/resilience/retryable_provider'
require 'codebase_index/operator/pipeline_guard'
require 'codebase_index/embedding/provider'
require 'tmpdir'

RSpec.describe 'Coordination + Resilience Integration', :integration do
  let(:tmpdir) { Dir.mktmpdir('coordination_test') }

  after { FileUtils.rm_rf(tmpdir) }

  # ── PipelineLock ────────────────────────────────────────────────

  describe 'PipelineLock' do
    let(:lock) do
      CodebaseIndex::Coordination::PipelineLock.new(
        lock_dir: tmpdir, name: 'extraction', stale_timeout: 2
      )
    end

    it 'acquires and releases a lock' do
      expect(lock.acquire).to be true
      expect(lock.locked?).to be true
      lock.release
      expect(lock.locked?).to be false
    end

    it 'prevents double acquisition' do
      lock.acquire
      second_lock = CodebaseIndex::Coordination::PipelineLock.new(
        lock_dir: tmpdir, name: 'extraction', stale_timeout: 2
      )

      expect(second_lock.acquire).to be false
    end

    it 'allows re-acquisition after release' do
      lock.acquire
      lock.release

      expect(lock.acquire).to be true
    end

    it 'executes a block with with_lock' do
      result = lock.with_lock { 42 }
      expect(result).to eq(42)
      expect(lock.locked?).to be false
    end

    it 'releases lock even if block raises' do
      expect do
        lock.with_lock { raise 'boom' }
      end.to raise_error(RuntimeError, 'boom')

      expect(lock.locked?).to be false
    end

    it 'raises LockError when lock is already held' do
      lock.acquire

      second_lock = CodebaseIndex::Coordination::PipelineLock.new(
        lock_dir: tmpdir, name: 'extraction', stale_timeout: 2
      )

      expect do
        second_lock.with_lock { 'should not run' }
      end.to raise_error(CodebaseIndex::Coordination::LockError)
    end

    it 'detects and replaces stale locks' do
      lock.acquire
      # Manually age the lock file
      lock_path = File.join(tmpdir, 'extraction.lock')
      FileUtils.touch(lock_path, mtime: Time.now - 10)

      new_lock = CodebaseIndex::Coordination::PipelineLock.new(
        lock_dir: tmpdir, name: 'extraction', stale_timeout: 2
      )
      expect(new_lock.acquire).to be true
    end

    it 'allows independent locks with different names' do
      extract_lock = CodebaseIndex::Coordination::PipelineLock.new(
        lock_dir: tmpdir, name: 'extraction', stale_timeout: 2
      )
      embed_lock = CodebaseIndex::Coordination::PipelineLock.new(
        lock_dir: tmpdir, name: 'embedding', stale_timeout: 2
      )

      expect(extract_lock.acquire).to be true
      expect(embed_lock.acquire).to be true

      extract_lock.release
      embed_lock.release
    end
  end

  # ── CircuitBreaker ──────────────────────────────────────────────

  describe 'CircuitBreaker' do
    let(:breaker) do
      CodebaseIndex::Resilience::CircuitBreaker.new(threshold: 3, reset_timeout: 1)
    end

    it 'starts in closed state' do
      expect(breaker.state).to eq(:closed)
    end

    it 'passes calls through in closed state' do
      result = breaker.call { 'success' }
      expect(result).to eq('success')
      expect(breaker.state).to eq(:closed)
    end

    it 'opens after reaching failure threshold' do
      3.times do
        breaker.call { raise 'fail' }
      rescue StandardError
        nil
      end

      expect(breaker.state).to eq(:open)
    end

    it 'rejects calls when open' do
      3.times do
        breaker.call { raise 'fail' }
      rescue StandardError
        nil
      end

      expect do
        breaker.call { 'should not run' }
      end.to raise_error(CodebaseIndex::Resilience::CircuitOpenError)
    end

    it 'transitions to half_open after reset_timeout' do
      3.times do
        breaker.call { raise 'fail' }
      rescue StandardError
        nil
      end

      expect(breaker.state).to eq(:open)
      sleep 1.1

      # Next call should transition to half_open and execute
      result = breaker.call { 'recovered' }
      expect(result).to eq('recovered')
      expect(breaker.state).to eq(:closed)
    end

    it 'resets to closed on success after half_open' do
      3.times do
        breaker.call { raise 'fail' }
      rescue StandardError
        nil
      end

      sleep 1.1

      result = breaker.call { 'ok' }
      expect(result).to eq('ok')
      expect(breaker.state).to eq(:closed)
    end

    it 're-opens if half_open call fails' do
      3.times do
        breaker.call { raise 'fail' }
      rescue StandardError
        nil
      end

      sleep 1.1

      begin
        breaker.call { raise 'still failing' }
      rescue StandardError
        nil
      end

      expect(breaker.state).to eq(:open)
    end
  end

  # ── RetryableProvider + CircuitBreaker ──────────────────────────

  describe 'RetryableProvider with CircuitBreaker' do
    let(:call_count) { [0] }

    let(:flaky_provider) do
      counter = call_count
      Class.new do
        include CodebaseIndex::Embedding::Provider::Interface

        define_method(:dimensions) { 3 }
        define_method(:model_name) { 'flaky-test' }

        define_method(:embed) do |_text|
          counter[0] += 1
          raise StandardError, "transient failure ##{counter[0]}" if counter[0] <= 2

          [0.1, 0.2, 0.3]
        end

        define_method(:embed_batch) do |texts|
          texts.map { |t| embed(t) }
        end
      end.new
    end

    let(:breaker) do
      CodebaseIndex::Resilience::CircuitBreaker.new(threshold: 5, reset_timeout: 60)
    end

    let(:retryable) do
      CodebaseIndex::Resilience::RetryableProvider.new(
        provider: flaky_provider,
        max_retries: 3,
        circuit_breaker: breaker
      )
    end

    it 'retries and eventually succeeds' do
      result = retryable.embed('test text')

      expect(result).to eq([0.1, 0.2, 0.3])
      expect(call_count[0]).to eq(3) # failed twice, succeeded on third
    end

    it 'reports dimensions from the underlying provider' do
      expect(retryable.dimensions).to eq(3)
    end

    it 'reports model_name from the underlying provider' do
      expect(retryable.model_name).to eq('flaky-test')
    end

    it 'raises CircuitOpenError when circuit is open' do
      always_fail = Class.new do
        include CodebaseIndex::Embedding::Provider::Interface

        define_method(:embed) { |_text| raise StandardError, 'always fail' }
        define_method(:embed_batch) { |texts| texts.map { |t| embed(t) } }
        define_method(:dimensions) { 3 }
        define_method(:model_name) { 'fail-provider' }
      end.new

      open_breaker = CodebaseIndex::Resilience::CircuitBreaker.new(threshold: 2, reset_timeout: 60)
      retryable_fail = CodebaseIndex::Resilience::RetryableProvider.new(
        provider: always_fail,
        max_retries: 1,
        circuit_breaker: open_breaker
      )

      # Exhaust retries to open the circuit
      2.times do
        retryable_fail.embed('fail')
      rescue StandardError
        nil
      end

      expect(open_breaker.state).to eq(:open)

      expect do
        retryable_fail.embed('should not work')
      end.to raise_error(CodebaseIndex::Resilience::CircuitOpenError)
    end
  end

  # ── PipelineGuard (file-based state) ────────────────────────────

  describe 'PipelineGuard' do
    let(:guard) do
      CodebaseIndex::Operator::PipelineGuard.new(state_dir: tmpdir, cooldown: 1)
    end

    it 'allows first operation' do
      expect(guard.allow?(:extraction)).to be true
    end

    it 'blocks within cooldown' do
      guard.record!(:extraction)
      expect(guard.allow?(:extraction)).to be false
    end

    it 'allows after cooldown expires' do
      guard.record!(:extraction)
      sleep 1.1
      expect(guard.allow?(:extraction)).to be true
    end

    it 'tracks different operations independently' do
      guard.record!(:extraction)

      expect(guard.allow?(:extraction)).to be false
      expect(guard.allow?(:embedding)).to be true
    end

    it 'records last run timestamp' do
      guard.record!(:extraction)

      last = guard.last_run(:extraction)
      expect(last).to be_a(Time)
      expect(last).to be_within(2).of(Time.now)
    end

    it 'persists state across instances' do
      guard.record!(:extraction)

      new_guard = CodebaseIndex::Operator::PipelineGuard.new(state_dir: tmpdir, cooldown: 1)
      expect(new_guard.allow?(:extraction)).to be false
    end
  end

  # ── Combined: PipelineLock + PipelineGuard ──────────────────────

  describe 'PipelineLock + PipelineGuard coordination' do
    it 'protects a pipeline run with both lock and guard' do
      lock = CodebaseIndex::Coordination::PipelineLock.new(
        lock_dir: tmpdir, name: 'extract', stale_timeout: 60
      )
      guard = CodebaseIndex::Operator::PipelineGuard.new(state_dir: tmpdir, cooldown: 1)

      # Guard allows
      expect(guard.allow?(:extraction)).to be true

      result = lock.with_lock do
        guard.record!(:extraction)
        'extraction complete'
      end

      expect(result).to eq('extraction complete')
      expect(lock.locked?).to be false

      # Guard now blocks
      expect(guard.allow?(:extraction)).to be false
    end
  end
end
