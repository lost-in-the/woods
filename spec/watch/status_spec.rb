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

  # Signal 0 succeeds for a zombie: a process that has exited but that its
  # parent has not reaped. A watcher re-parented to a PID 1 that never reaps
  # (a container without an init) leaves one behind when killed (#993).
  describe 'zombie liveness (#993)' do
    let(:status) { described_class.new(output_dir: output_dir) }
    let(:proc_status) { "/proc/#{Process.pid}/status" }

    def proc_state(letter)
      "Name:\truby\nUmask:\t0022\nState:\t#{letter}\nTgid:\t#{Process.pid}\n"
    end

    before do
      status.write(state: :running)
      allow(Process).to receive(:kill).and_call_original
      allow(Process).to receive(:kill).with(0, Process.pid).and_return(1)
      allow(File).to receive(:binread).and_call_original
    end

    context 'on Linux' do
      before { stub_const('RUBY_PLATFORM', 'x86_64-linux') }

      it 'reads a pid whose /proc status is Z as dead' do
        allow(File).to receive(:binread).with(proc_status).and_return(proc_state('Z (zombie)'))

        expect(status.alive?).to be false
        expect(status.report).to include('state' => 'dead', 'recorded_state' => 'running', 'alive' => false)
      end

      ['R (running)', 'S (sleeping)'].each do |state|
        it "reads a pid whose /proc status is #{state} as alive" do
          allow(File).to receive(:binread).with(proc_status).and_return(proc_state(state))

          expect(status.alive?).to be true
          expect(status.report).to include('state' => 'running', 'alive' => true)
        end
      end

      it 'reads the state when the process name is not valid UTF-8' do
        name = "caf\xC3\xA9 \xFF".b
        allow(File).to receive(:binread).with(proc_status)
                                        .and_return("Name:\t#{name}\nState:\tZ (zombie)\n".b)

        expect(status.alive?).to be false
      end

      [Errno::EACCES, Errno::ENOENT].each do |error|
        it "falls back to signal 0 when /proc status raises #{error}" do
          allow(File).to receive(:binread).with(proc_status).and_raise(error)

          expect(status.alive?).to be true
        end
      end

      it 'still reads a pid signal 0 cannot find as dead without consulting /proc' do
        allow(Process).to receive(:kill).with(0, Process.pid).and_raise(Errno::ESRCH)
        expect(File).not_to receive(:binread).with(proc_status)

        expect(status.alive?).to be false
      end
    end

    it 'keeps signal 0 alone off Linux' do
      stub_const('RUBY_PLATFORM', 'arm64-darwin24')
      expect(File).not_to receive(:binread).with(proc_status)

      expect(status.alive?).to be true
    end

    it 'reads a real unreaped child as dead', if: RUBY_PLATFORM.include?('linux') && Process.respond_to?(:fork) do
      pid = fork { exit!(0) }
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until File.binread("/proc/#{pid}/status")[/^State:\s*(\S)/, 1] == 'Z'
          raise 'child never became a zombie' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.01
        end
        status.write(state: :running, pid: pid)

        expect(status.alive?).to be false
        expect(status.report).to include('state' => 'dead')
      ensure
        Process.wait(pid)
      end
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

  # A daemon that dies cannot amend its own record, so `running` outlives the
  # process that wrote it. The reported `state` is derived from liveness at
  # read time and the daemon's word is kept as `recorded_state`.
  describe '#report' do
    let(:now) { Time.utc(2026, 1, 1, 12, 0, 0) }
    let(:writer) { described_class.new(output_dir: output_dir, clock: -> { now.iso8601 }) }

    def reader(at: now)
      described_class.new(output_dir: output_dir, clock: -> { at.iso8601 })
    end

    it 'reports running while the daemon is alive' do
      writer.write(state: :running, generation: 3)
      allow(Process).to receive(:kill).with(0, Process.pid).and_return(1)

      expect(reader.report).to include('state' => 'running', 'recorded_state' => 'running',
                                       'alive' => true, 'generation' => 3)
    end

    it 'leaves a degraded daemon degraded while it is alive' do
      writer.write(state: :degraded, reason: 'reload failed')
      allow(Process).to receive(:kill).with(0, Process.pid).and_return(1)

      expect(reader.report).to include('state' => 'degraded', 'recorded_state' => 'degraded',
                                       'alive' => true, 'reason' => 'reload failed')
    end

    it 'reports dead when the same-host pid is gone' do
      writer.write(state: :running)
      allow(Process).to receive(:kill).with(0, Process.pid).and_raise(Errno::ESRCH)

      expect(reader.report).to include('state' => 'dead', 'recorded_state' => 'running', 'alive' => false)
    end

    it 'reports stale when the record has outlived STALE_AFTER' do
      writer.write(state: :running, host: 'another-container')

      report = reader(at: now + described_class::STALE_AFTER + 60).report(trust_foreign_host: true)
      expect(report).to include('state' => 'stale', 'recorded_state' => 'running', 'alive' => false)
    end

    it 'prefers dead over stale when both hold' do
      writer.write(state: :running)
      allow(Process).to receive(:kill).with(0, Process.pid).and_raise(Errno::ESRCH)

      expect(reader(at: now + described_class::STALE_AFTER + 60).report).to include('state' => 'dead')
    end

    # The field case: written inside a container, read on the host. Neither
    # dead nor stale, but `running` beside `alive: false` is the contradiction.
    it 'reports a fresh foreign record it is not trusted to check as unverified' do
      writer.write(state: :degraded, host: 'another-container', reason: 'reload failed')

      expect(reader.report(trust_foreign_host: false))
        .to include('state' => 'unverified', 'recorded_state' => 'degraded', 'alive' => false)
      expect(reader.report(trust_foreign_host: true))
        .to include('state' => 'degraded', 'recorded_state' => 'degraded', 'alive' => true)
    end

    it 'leaves stopped alone' do
      writer.write(state: :stopped)

      expect(reader.report).to include('state' => 'stopped', 'recorded_state' => 'stopped', 'alive' => false)
    end

    it 'reports stopped with its reason when no daemon has run' do
      expect(reader.report).to include('state' => 'stopped', 'recorded_state' => 'stopped', 'alive' => false)
    end
  end
end
