# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/watch/status'

RSpec.describe Woods::Watch::Status do
  let(:output_dir) { Dir.mktmpdir('woods_status') }

  after { FileUtils.rm_rf(output_dir) }

  describe 'foreign-host liveness (#321)' do
    let(:now) { Time.utc(2026, 9, 15, 12) }
    let(:status) { described_class.new(output_dir: output_dir, clock: -> { now.iso8601 }) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WOODS_WATCH_TRUST_FOREIGN_HOST').and_return(nil)
      status.write(state: :running, host: 'another-container')
    end

    it 'requires an explicit opt-in' do
      expect(status.alive?).to be false
      expect(status.alive?(trust_foreign_host: true)).to be true
    end

    it 'uses the environment default while allowing an explicit override' do
      allow(ENV).to receive(:[]).with('WOODS_WATCH_TRUST_FOREIGN_HOST').and_return('1')
      expect(status.alive?).to be true
      expect(status.alive?(trust_foreign_host: false)).to be false
    end

    it 'never looks up a foreign pid in the local process table' do
      expect(Process).not_to receive(:kill)
      expect(status.alive?(trust_foreign_host: true)).to be true
    end

    it 'treats a fresh degraded daemon as alive' do
      status.write(state: :degraded, host: 'another-container', reason: 'reload failed')
      expect(status.alive?(trust_foreign_host: true)).to be true
    end

    it 'does not believe a stopped daemon' do
      status.write(state: :stopped, host: 'another-container')
      expect(status.alive?(trust_foreign_host: true)).to be false
    end

    [nil, 'invalid', '12:00', '2026-09-15', 123,
     '2026-09-15T11:44:59Z', '2026-09-16T12:00:00Z'].each do |timestamp|
      it "rejects an invalid or out-of-window timestamp #{timestamp.inspect}" do
        status.write(state: :running, host: 'another-container', updated_at: timestamp)
        expect(status.alive?(trust_foreign_host: true)).to be false
      end
    end

    [nil, '47', 0, -1].each do |pid|
      it "rejects malformed foreign pid #{pid.inspect} without consulting the local process table" do
        status.write(state: :running, host: 'another-container', pid: pid)
        expect(Process).not_to receive(:kill)
        expect(status.alive?(trust_foreign_host: true)).to be false
      end
    end

    it 'accepts the age boundary and a small bounded future clock skew' do
      [now - described_class::STALE_AFTER, now + 30].each do |timestamp|
        status.write(state: :running, host: 'another-container', updated_at: timestamp.iso8601)
        expect(status.alive?(trust_foreign_host: true)).to be true
      end
      status.write(state: :running, host: 'another-container', updated_at: (now + 31).iso8601)
      expect(status.alive?(trust_foreign_host: true)).to be false
    end

    it 'still checks same-host pids when foreign trust is enabled' do
      status.write(state: :running)
      allow(Process).to receive(:kill).with(0, Process.pid).and_raise(Errno::ESRCH)
      expect(status.alive?(trust_foreign_host: true)).to be false
    end

    it 'preserves pid checks for legacy records without a host' do
      status.write(state: :running, host: nil)
      expect(Process).to receive(:kill).with(0, Process.pid).and_return(1)
      expect(status.alive?(trust_foreign_host: true)).to be true
    end
  end

  # The one artifact with a documented cross-boundary consumer: host-side
  # worktree hooks read watch_status.json through a bind mount, so it must
  # be world-readable (O1). Everything else Woods writes stays at 0600.
  describe 'status file visibility' do
    it 'writes watch_status.json world-readable by design' do
      described_class.new(output_dir: output_dir).write(state: :running)

      path = File.join(output_dir, described_class::FILENAME)
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end
  end

  # The injected clock exists so a spec can drive staleness without sleeping
  # for a quarter of an hour. Reading the left-hand side of the comparison from
  # `Time.now` regardless made it a no-op for the one thing it is for.
  describe 'freshness against the injected clock' do
    it 'disbelieves a record older than the window' do
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      described_class.new(output_dir: output_dir, clock: -> { now.iso8601 })
                     .write(state: :running)

      later = described_class.new(
        output_dir: output_dir,
        clock: -> { (now + described_class::STALE_AFTER + 60).iso8601 }
      )
      expect(later.alive?).to be false
    end

    it 'believes a record inside the window' do
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      described_class.new(output_dir: output_dir, clock: -> { now.iso8601 })
                     .write(state: :running)

      soon = described_class.new(
        output_dir: output_dir,
        clock: -> { (now + 60).iso8601 }
      )
      expect(soon.alive?).to be true
    end
  end
end
