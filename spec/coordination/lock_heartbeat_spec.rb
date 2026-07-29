# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/coordination/lock_heartbeat'

RSpec.describe Woods::Coordination::LockHeartbeat do
  let(:lock_dir) { Dir.mktmpdir('woods_lock_hb') }

  after { FileUtils.rm_rf(lock_dir) }

  def build_lock(stale_timeout:)
    Woods::Coordination::PipelineLock.new(
      lock_dir: lock_dir, name: 'extraction', stale_timeout: stale_timeout
    )
  end

  describe 'the block contract' do
    it 'returns the block value' do
      lock = build_lock(stale_timeout: 5)
      lock.acquire

      expect(described_class.run(lock, tick: 0.01) { :result }).to eq(:result)
    end

    it 'propagates the block exception' do
      lock = build_lock(stale_timeout: 5)
      lock.acquire

      expect { described_class.run(lock, tick: 0.01) { raise ArgumentError, 'real error' } }
        .to raise_error(ArgumentError, 'real error')
    end

    # `join` re-raises a thread's exception and the join sits in an `ensure`, so
    # without isolation a heartbeat failure would replace the caller's error —
    # exactly when the real message matters most.
    # The block must outlive an interval, or the heartbeat never ticks and the
    # rescue under test is never entered — the example then passes with the
    # protection deleted, which is exactly the gap these exist to close. The
    # `have_received` assertion is what makes that failure visible.
    it 'does not let a failing heartbeat become the caller error' do
      lock = build_lock(stale_timeout: 0.03)
      lock.acquire
      allow(lock).to receive(:touch).and_raise('heartbeat blew up')

      expect do
        described_class.run(lock, tick: 0.01) do
          sleep 0.1
          raise ArgumentError, 'real error'
        end
      end
        .to raise_error(ArgumentError, 'real error')
      expect(lock).to have_received(:touch).at_least(:once)
    end

    it 'does not let a failing heartbeat fail a successful run' do
      lock = build_lock(stale_timeout: 0.03)
      lock.acquire
      allow(lock).to receive(:touch).and_raise('heartbeat blew up')

      expect(described_class.run(lock, tick: 0.01) do
        sleep 0.1
        :ok
      end).to eq(:ok)
      expect(lock).to have_received(:touch).at_least(:once)
    end
  end

  describe 'refreshing' do
    it 'keeps a held lock un-retirable across a run longer than the window' do
      holder = build_lock(stale_timeout: 0.2)
      holder.acquire

      described_class.run(holder, tick: 0.02) { sleep 0.5 }

      expect(build_lock(stale_timeout: 0.2).acquire).to be false
    end

    it 'leaves an untouched lock retirable, which is what makes that a real guard' do
      holder = build_lock(stale_timeout: 0.2)
      holder.acquire
      sleep 0.5

      expect(build_lock(stale_timeout: 0.2).acquire).to be true
    end

    it 'stops the thread when the block finishes' do
      lock = build_lock(stale_timeout: 5)
      lock.acquire
      before = Thread.list.size

      described_class.run(lock, tick: 0.01) { :done }

      expect(Thread.list.size).to be <= before
    end
  end

  describe 'pacing' do
    # Derived from the lock, not from a constant that happens to match. A lock
    # built with any other stale_timeout would otherwise get a mis-paced
    # heartbeat with nothing to notice it.
    it 'derives its interval from the lock it refreshes' do
      lock = build_lock(stale_timeout: 9.0)

      expect(described_class.new(lock).instance_variable_get(:@interval)).to eq(3.0)
    end
  end
end
