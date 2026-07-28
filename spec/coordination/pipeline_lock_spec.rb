# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/coordination/pipeline_lock'

RSpec.describe Woods::Coordination::PipelineLock do
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
      end.to raise_error(Woods::Coordination::LockError)
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

    it 'handles ENOENT when lock file is deleted between exist? and mtime checks' do
      lock_path = File.join(lock_dir, 'extraction.lock')
      # Create a lock file so File.exist? returns true
      File.write(lock_path, '{}')

      # Simulate the race: File.exist? sees the file, but File.mtime raises
      # ENOENT for the lock path (other paths, e.g. a graveyard file, behave
      # normally).
      allow(File).to receive(:mtime).and_call_original
      allow(File).to receive(:mtime).with(lock_path).and_raise(Errno::ENOENT)

      new_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect { new_lock.acquire }.not_to raise_error
    end
  end

  describe 'release ownership' do
    let(:lock_path) { File.join(lock_dir, 'extraction.lock') }

    it 'does not delete a lock file that was taken over by another holder' do
      lock.acquire
      # Simulate a legitimate takeover after this holder went stale:
      # the file now carries someone else's token.
      File.write(lock_path, JSON.generate(pid: 99_999, token: 'someone-elses-token'))

      lock.release

      expect(File.exist?(lock_path)).to be true
    end

    it 'deletes the lock file when it still owns it' do
      lock.acquire
      lock.release

      expect(File.exist?(lock_path)).to be false
    end

    it 'handles the lock file already being gone' do
      lock.acquire
      FileUtils.rm_f(lock_path)

      expect { lock.release }.not_to raise_error
      expect(lock.locked?).to be false
    end
  end

  describe 'stale takeover race' do
    let(:lock_path) { File.join(lock_dir, 'extraction.lock') }

    it 'backs off when another process retires the stale lock first' do
      File.write(lock_path, '{}')
      FileUtils.touch(lock_path, mtime: Time.now - 7200)

      # The racing process wins the atomic rename between our stale check
      # and our retirement attempt.
      allow(File).to receive(:rename).and_raise(Errno::ENOENT)

      expect(lock.acquire).to be false
      expect(lock.locked?).to be false
    end

    it 'restores the file and backs off if the retired lock is no longer stale' do
      # Simulates a competitor that already retired the stale lock and
      # created a FRESH one between our stale? check and our rename: retiring
      # blindly would clobber a live holder's lock and let both processes run.
      File.write(lock_path, JSON.generate(token: 'competitor-fresh'))
      # mtime is now (fresh), i.e. not older than stale_timeout.

      expect(lock.send(:retire_stale_lock)).to be false
      expect(File.exist?(lock_path)).to be true
      expect(JSON.parse(File.read(lock_path))['token']).to eq('competitor-fresh')
    end

    it 'restore_lock does not clobber a lock created in the gap' do
      # After we rename a captured lock aside, a newer holder may O_EXCL-create
      # at @lock_path. Restoring via rename would overwrite it (double-hold);
      # the link-based restore must leave the newer holder untouched and simply
      # discard our aside copy.
      graveyard = "#{lock_path}.grave"
      File.write(graveyard, JSON.generate(token: 'ours-captured'))
      File.write(lock_path, JSON.generate(token: 'newer-holder'))

      lock.send(:restore_lock, graveyard)

      expect(JSON.parse(File.read(lock_path))['token']).to eq('newer-holder')
      expect(File.exist?(graveyard)).to be false
    end
  end

  describe 'concurrent acquisition' do
    it 'only allows one thread to acquire the lock' do
      results = []
      mutex = Mutex.new
      barrier = Queue.new

      thread_count = 10
      threads = thread_count.times.map do
        Thread.new do
          l = described_class.new(lock_dir: lock_dir, name: 'extraction')
          acquired = l.acquire
          mutex.synchronize { results << acquired }
          if acquired
            # Wait until all other threads have recorded their results
            barrier.pop
            l.release
          end
        end
      end

      # Poll until all threads have reported results
      poll_until(timeout: 5) { mutex.synchronize { results.size == thread_count } }
      barrier.push(:release)
      threads.each(&:join)

      # Exactly one thread should have acquired the lock
      expect(results.count(true)).to eq(1)
    end
  end

  # `touch` gated on `locked?` — `@held && File.exist?` — which stays true after
  # a contender retires us and puts its own lock at the same path. A retired
  # holder then refreshed the SUCCESSOR's mtime, so if that successor crashed,
  # its lock never aged out while the retired process lived and every writer was
  # blocked until it exited.
  #
  # Being retired mid-run is the exact scenario a heartbeat exists to prevent,
  # so it is also the state a heartbeat is most likely to find itself in when it
  # fails to.
  describe '#touch ownership' do
    let(:lock_dir) { Dir.mktmpdir('woods_touch_own') }

    after { FileUtils.rm_rf(lock_dir) }

    def build(stale_timeout: 0.2)
      described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: stale_timeout)
    end

    it 'refuses to refresh a lock a contender has taken over' do
      holder = build
      holder.acquire
      sleep 0.3
      expect(build.acquire).to be true

      expect(holder.touch).to be false
    end

    it 'does not move the successor mtime' do
      holder = build
      holder.acquire
      sleep 0.3
      build.acquire
      before = File.mtime(File.join(lock_dir, 'extraction.lock'))
      sleep 0.05

      holder.touch

      expect(File.mtime(File.join(lock_dir, 'extraction.lock'))).to eq(before)
    end

    it 'stops believing it holds the lock once it learns otherwise' do
      holder = build
      holder.acquire
      sleep 0.3
      build.acquire

      holder.touch

      expect(holder.locked?).to be false
    end

    it 'still refreshes for the live holder' do
      holder = build(stale_timeout: 5)
      holder.acquire

      expect(holder.touch).to be true
    end

    it 'refuses after its own release' do
      holder = build(stale_timeout: 5)
      holder.acquire
      holder.release

      expect(holder.touch).to be false
    end
  end
end
