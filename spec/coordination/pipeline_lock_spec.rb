# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'codebase_index'
require 'codebase_index/coordination/pipeline_lock'

RSpec.describe CodebaseIndex::Coordination::PipelineLock do
  let(:lock_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(lock_dir) }

  subject(:lock) { described_class.new(lock_dir: lock_dir, name: 'extraction') }

  describe '#acquire' do
    it 'creates a lock file' do
      lock.acquire
      expect(File.exist?(File.join(lock_dir, 'extraction.lock'))).to be true
    end

    it 'returns true on successful acquisition' do
      expect(lock.acquire).to be true
    end

    it 'returns false if already locked' do
      lock.acquire
      other_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect(other_lock.acquire).to be false
    end
  end

  describe '#release' do
    it 'removes the lock file' do
      lock.acquire
      lock.release
      expect(File.exist?(File.join(lock_dir, 'extraction.lock'))).to be false
    end

    it 'does not raise if not locked' do
      expect { lock.release }.not_to raise_error
    end
  end

  describe '#with_lock' do
    it 'yields the block when lock acquired' do
      result = lock.with_lock { 42 }
      expect(result).to eq(42)
    end

    it 'releases lock after block completes' do
      lock.with_lock { 'work' }
      expect(lock.locked?).to be false
    end

    it 'releases lock on exception' do
      begin
        lock.with_lock { raise 'boom' }
      rescue RuntimeError
        nil
      end
      expect(lock.locked?).to be false
    end

    it 'raises LockError when lock unavailable' do
      lock.acquire
      other_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect do
        other_lock.with_lock { 'work' }
      end.to raise_error(CodebaseIndex::Coordination::LockError)
    end
  end

  describe '#locked?' do
    it 'returns false when not locked' do
      expect(lock.locked?).to be false
    end

    it 'returns true when locked' do
      lock.acquire
      expect(lock.locked?).to be true
    end
  end

  describe 'stale lock detection' do
    it 'treats locks older than timeout as stale' do
      lock.acquire
      lock_path = File.join(lock_dir, 'extraction.lock')
      # Backdate the lock file
      FileUtils.touch(lock_path, mtime: Time.now - 3600)

      stale_lock = described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: 1800)
      expect(stale_lock.acquire).to be true
    end
  end

  describe 'concurrent acquisition' do
    it 'only allows one thread to acquire the lock' do
      results = []
      mutex = Mutex.new
      threads = 10.times.map do
        Thread.new do
          l = described_class.new(lock_dir: lock_dir, name: 'extraction')
          acquired = l.acquire
          mutex.synchronize { results << acquired }
          sleep(0.05) if acquired # Hold lock briefly
          l.release if acquired
        end
      end
      threads.each(&:join)

      # Exactly one thread should have acquired the lock
      expect(results.count(true)).to eq(1)
    end
  end
end
