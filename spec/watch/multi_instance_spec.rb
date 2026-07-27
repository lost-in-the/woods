# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/watch/daemon'
require 'woods/mcp/index_reader'

# Multi-instance operation (#164, phase 4).
#
# The topology to survive: a worktree manager provisions a canonical checkout
# plus N agent slots, each an independent Rails.root with its own tmp/woods,
# and several sessions run concurrently — some sharing a worktree.
#
# Disjointness across worktrees is the foundation and is structural (separate
# output dirs), so what actually needs testing is what happens *within* one
# worktree: several writers, several readers, and a daemon that should not
# hold memory in a slot nobody is using.
RSpec.describe 'Watch daemon multi-instance operation' do
  let(:roots) { Array.new(3) { Dir.mktmpdir('woods_mi_root') } }
  let(:outputs) { Array.new(3) { Dir.mktmpdir('woods_mi_out') } }

  after { FileUtils.rm_rf(roots + outputs) }

  # A stub extractor that does what the real one does at the boundaries that
  # matter here: writes a file into the index, then bumps the generation last.
  def extractor_for(output_dir, marker:, delay: 0)
    double("extractor-#{marker}").tap do |stub|
      allow(stub).to receive(:extract_changed) do
        sleep(delay)
        FileUtils.mkdir_p(File.join(output_dir, 'models'))
        File.write(File.join(output_dir, 'models', "#{marker}.json"),
                   JSON.generate('identifier' => marker))
        Woods::Generation.new(output_dir: output_dir).bump!(reason: 'incremental')
        [marker]
      end
      allow(stub).to receive(:extract_all).and_return({})
    end
  end

  def daemon_for(index, marker:, delay: 0, **overrides)
    Woods::Watch::Daemon.new(
      output_dir: outputs[index],
      root: roots[index],
      extractor_factory: -> { extractor_for(outputs[index], marker: marker, delay: delay) },
      reloader: instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true),
      debounce: 0,
      **overrides
    )
  end

  def touch(index, relative)
    path = File.join(roots[index], relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    relative
  end

  describe 'disjointness across worktrees' do
    it 'keeps each worktree index to its own units, with independent generations' do
      threads = 3.times.map do |i|
        touch(i, 'config/locales/en.yml')
        Thread.new { daemon_for(i, marker: "Unit#{i}").process(['config/locales/en.yml']) }
      end
      threads.each(&:join)

      3.times do |i|
        units = Dir[File.join(outputs[i], 'models', '*.json')].map { |f| File.basename(f, '.json') }
        expect(units).to eq(["Unit#{i}"])
        expect(Woods::Generation.new(output_dir: outputs[i]).current.number).to eq(1)
      end
    end
  end

  describe 'writer serialization within one worktree' do
    it 'yields to another writer holding the extraction lock rather than racing' do
      touch(0, 'config/locales/en.yml')
      other_writer = Woods::Coordination::PipelineLock.new(
        lock_dir: outputs[0], name: Woods::Watch::Daemon::LOCK_NAME
      )
      expect(other_writer.acquire).to be(true)

      result = daemon_for(0, marker: 'Blocked').process(['config/locales/en.yml'])

      expect(result[:action]).to eq(:contended)
      expect(result[:state]).to eq(:degraded)
      expect(Dir[File.join(outputs[0], 'models', '*.json')]).to be_empty
    ensure
      other_writer&.release
    end

    # A cycle skipped for contention must not lose its paths — the files
    # really did change, and no later event will mention them again.
    it 'carries the skipped paths into the next cycle' do
      touch(0, 'config/locales/en.yml')
      daemon = daemon_for(0, marker: 'Carried')
      other_writer = Woods::Coordination::PipelineLock.new(
        lock_dir: outputs[0], name: Woods::Watch::Daemon::LOCK_NAME
      )
      other_writer.acquire
      expect(daemon.process(['config/locales/en.yml'])[:action]).to eq(:contended)
      other_writer.release

      # A later, unrelated event — the earlier paths ride along with it. The
      # drain is inside #process, so an embedded caller gets it too.
      touch(0, 'config/locales/de.yml')
      result = daemon.process(['config/locales/de.yml'])

      expect(result[:action]).to eq(:incremental)
      expect(result[:count]).to eq(2)
    end

    # The other two ways a cycle can fail to land its work. Contention was the
    # only one originally covered, and a failed reload was in fact dropping the
    # batch.
    it 'carries the paths forward when a reload fails' do
      touch(0, 'app/models/user.rb')
      reloader = instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true)
      allow(reloader).to receive(:reload!).and_raise(SyntaxError, 'unexpected end')
      daemon = daemon_for(0, marker: 'Reloaded', reloader: reloader)

      expect(daemon.process(['app/models/user.rb'])[:state]).to eq(:degraded)

      # The half-typed file is fixed; the event names only that file, but the
      # batch it was part of has to be retried in full.
      allow(reloader).to receive(:reload!).and_return(true)
      expect(daemon.process([])[:count]).to eq(1)
      expect(Dir[File.join(outputs[0], 'models', '*.json')]).not_to be_empty
    end

    it 'carries the paths forward when extraction raises' do
      touch(0, 'config/locales/en.yml')
      exploding = double('extractor')
      allow(exploding).to receive(:extract_changed).and_raise(StandardError, 'boom')
      daemon = Woods::Watch::Daemon.new(
        output_dir: outputs[0], root: roots[0], extractor_factory: -> { exploding },
        reloader: instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true),
        debounce: 0
      )

      expect(daemon.process(['config/locales/en.yml'])[:state]).to eq(:degraded)
      # Nothing new happened, but the earlier batch is still owed.
      expect(daemon.process([])[:count]).to eq(1)
    end

    it 'leaves no orphaned lock behind after a successful cycle' do
      touch(0, 'config/locales/en.yml')
      daemon_for(0, marker: 'Clean').process(['config/locales/en.yml'])

      expect(File).not_to exist(File.join(outputs[0], "#{Woods::Watch::Daemon::LOCK_NAME}.lock"))
    end

    it 'releases the lock even when extraction raises' do
      touch(0, 'config/locales/en.yml')
      exploding = double('extractor')
      allow(exploding).to receive(:extract_changed).and_raise(StandardError, 'boom')
      daemon = Woods::Watch::Daemon.new(
        output_dir: outputs[0], root: roots[0], extractor_factory: -> { exploding },
        reloader: instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true),
        debounce: 0
      )

      daemon.process(['config/locales/en.yml'])

      expect(File).not_to exist(File.join(outputs[0], "#{Woods::Watch::Daemon::LOCK_NAME}.lock"))
    end

    it 'serializes concurrent cycles against the same index without deadlocking' do
      touch(0, 'config/locales/en.yml')
      results = []
      mutex = Mutex.new

      threads = 4.times.map do |i|
        Thread.new do
          result = daemon_for(0, marker: "Concurrent#{i}", delay: 0.02)
                   .process(['config/locales/en.yml'])
          mutex.synchronize { results << result[:action] }
        end
      end
      threads.each { |thread| expect(thread.join(15)).not_to be_nil }

      # Whoever wins the lock extracts; the rest yield. Nobody hangs, nobody
      # raises, and no lock is left behind.
      expect(results.size).to eq(4)
      expect(results - %i[incremental contended]).to be_empty
      expect(results).to include(:incremental)
      expect(File).not_to exist(File.join(outputs[0], "#{Woods::Watch::Daemon::LOCK_NAME}.lock"))
    end
  end

  describe 'reader multiplicity' do
    it 'lets several readers of one index converge on fresh data with no coordination' do
      touch(0, 'config/locales/en.yml')
      File.write(File.join(outputs[0], 'manifest.json'), JSON.generate('counts' => {}))
      readers = Array.new(3) { Woods::MCP::IndexReader.new(outputs[0]) }
      readers.each(&:manifest)

      daemon_for(0, marker: 'Shared').process(['config/locales/en.yml'])
      published = Woods::Generation.new(output_dir: outputs[0]).current.number

      # Each reader notices independently. No shared server, no reload call.
      readers.each do |reader|
        reader.manifest
        expect(reader.loaded_generation).to eq(published)
      end
    end
  end

  describe 'idle TTL' do
    it 'exits after the idle window so a dormant slot stops holding memory' do
      idle_watcher = Class.new do
        def start(&_on_change)
          sleep(0.05) until @stopped
        end

        def stop
          @stopped = true
        end
      end.new

      daemon = daemon_for(0, marker: 'Idle', watcher: idle_watcher, idle_timeout: 0.2)

      reason = Timeout.timeout(15) { daemon.run }

      expect(reason).to eq(:idle)
      expect(JSON.parse(File.read(File.join(outputs[0], Woods::Watch::Status::FILENAME))))
        .to include('state' => 'stopped', 'reason' => 'idle')
    end

    # Previously this asserted `not_to receive(:stop)` on a double that was
    # never handed to the daemon, and never called `run` — so the only live
    # assertion was a private-method check and the example could not fail.
    # Drive the real heartbeat against a watcher the daemon actually holds.
    it 'stays up indefinitely when no idle timeout is configured' do
      watcher = instance_spy(Woods::Watch::PollingWatcher)
      daemon = daemon_for(0, marker: 'Persistent', watcher: watcher)

      heartbeat = daemon.send(:start_heartbeat, watcher)
      sleep 0.3
      heartbeat.kill

      expect(daemon.send(:idle_expired?)).to be(false)
      expect(watcher).not_to have_received(:stop)
    end

    it 'stops the watcher it was given once the idle window passes' do
      watcher = instance_spy(Woods::Watch::PollingWatcher)
      daemon = daemon_for(0, marker: 'Idles', watcher: watcher, idle_timeout: 0.1)
      daemon.instance_variable_set(:@last_event_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5)

      heartbeat = daemon.send(:start_heartbeat, watcher)
      sleep 0.3
      heartbeat.kill

      expect(watcher).to have_received(:stop)
    end
  end

  # Without a heartbeat, a healthy but quiet daemon reads as dead once its
  # record ages past Status::STALE_AFTER — and every caller that stands down
  # for a live daemon starts contending with it instead.
  describe 'heartbeat' do
    it 're-stamps the status file so a quiet daemon stays believable' do
      daemon = daemon_for(0, marker: 'Beat')
      status = Woods::Watch::Status.new(output_dir: outputs[0])
      daemon.send(:publish_status, :running, reason: nil)
      first = JSON.parse(File.read(status.path))['updated_at']

      sleep 1.05 # the record carries whole-second ISO8601 precision
      daemon.send(:restamp_status)

      expect(JSON.parse(File.read(status.path))['updated_at']).not_to eq(first)
      expect(status.alive?).to be(true)
    end

    it 'republishes a degraded state rather than claiming recovery' do
      daemon = daemon_for(0, marker: 'Stuck')
      daemon.send(:publish_status, :degraded, reason: 'SyntaxError: unexpected end')
      daemon.send(:restamp_status)

      record = JSON.parse(File.read(Woods::Watch::Status.new(output_dir: outputs[0]).path))
      expect(record).to include('state' => 'degraded', 'reason' => 'SyntaxError: unexpected end')
    end

    it 'beats often enough to stay inside the staleness window' do
      expect(Woods::Watch::Daemon::HEARTBEAT_INTERVAL).to be < Woods::Watch::Status::STALE_AFTER
      expect(daemon_for(0, marker: 'Tick').send(:heartbeat_tick))
        .to be <= Woods::Watch::Status::STALE_AFTER / 2.0
    end
  end

  describe 'liveness advertisement' do
    # A session-start hook that would run woods:incremental can skip it when
    # a daemon is already on the job.
    it 'reports a live daemon while it is running' do
      status = Woods::Watch::Status.new(output_dir: outputs[0])
      status.write(state: :running, generation: 1)

      expect(status.alive?).to be(true)
    end

    it 'does not believe a record whose process is gone' do
      status = Woods::Watch::Status.new(output_dir: outputs[0])
      status.write(state: :running, generation: 1)
      record = JSON.parse(File.read(status.path)).merge('pid' => 999_999)
      File.write(status.path, JSON.generate(record))

      expect(status.alive?).to be(false)
    end

    it 'does not believe a record older than the staleness window' do
      status = Woods::Watch::Status.new(output_dir: outputs[0])
      status.write(state: :running, generation: 1)

      expect(status.alive?(max_age: -1)).to be(false)
    end

    it 'reports a degraded daemon as still alive — it is on the job, just stuck' do
      status = Woods::Watch::Status.new(output_dir: outputs[0])
      status.write(state: :degraded, reason: 'SyntaxError', generation: 1)

      expect(status.alive?).to be(true)
    end

    it 'reports nothing alive when no daemon has run' do
      expect(Woods::Watch::Status.new(output_dir: outputs[0]).alive?).to be(false)
    end
  end
end
