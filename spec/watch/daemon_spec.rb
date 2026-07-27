# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/watch/daemon'

RSpec.describe Woods::Watch::Daemon do
  let(:root) { Dir.mktmpdir('woods_watch_root') }
  let(:output_dir) { Dir.mktmpdir('woods_watch_out') }
  # The real extractor bumps the generation as the last write of a successful
  # run (that is the contract the daemon reads), so the stub does too.
  let(:extractor) do
    instance_spy('Woods::Extractor').tap do |double|
      allow(double).to receive(:extract_changed) { publish_generation('incremental') && ['Thing'] }
      allow(double).to receive(:extract_all) { publish_generation('full') && {} }
    end
  end
  let(:reloader) { instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true) }

  after { FileUtils.rm_rf([root, output_dir]) }

  def build(**overrides)
    described_class.new(
      output_dir: output_dir,
      root: root,
      extractor_factory: -> { extractor },
      reloader: reloader,
      debounce: 0,
      **overrides
    )
  end

  def publish_generation(reason)
    Woods::Generation.new(output_dir: output_dir).bump!(reason: reason)
  end

  def touch(relative)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    relative
  end

  def status
    JSON.parse(File.read(File.join(output_dir, Woods::Watch::Status::FILENAME)))
  end

  describe 'classification' do
    it 'does nothing for paths no extractor cares about' do
      result = build.process(['README.md'])

      expect(result[:action]).to eq(:ignore)
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'extracts directly for files Woods reads as bytes' do
      touch('config/locales/en.yml')

      result = build.process(['config/locales/en.yml'])

      expect(result[:action]).to eq(:incremental)
      expect(reloader).not_to have_received(:reload!)
      expect(extractor).to have_received(:extract_changed)
    end

    it 'reloads before extracting when an autoloaded constant changed' do
      touch('app/models/user.rb')

      result = build.process(['app/models/user.rb'])

      expect(reloader).to have_received(:reload!)
      expect(result[:action]).to eq(:incremental)
    end
  end

  describe 'restart triggers' do
    it 'refuses to extract when boot-captured state changed' do
      result = build.process(['config/initializers/redis.rb'])

      expect(result[:action]).to eq(:restart)
      expect(result[:state]).to eq(:degraded)
      expect(result[:reason]).to include('config/initializers/redis.rb')
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'escalates a reload to a restart when the app cannot reload' do
      allow(reloader).to receive(:enabled?).and_return(false)

      result = build.process(['app/models/user.rb'])

      expect(result[:action]).to eq(:restart)
      expect(reloader).not_to have_received(:reload!)
    end

    it 'records the restart in the status file so a reader can see why' do
      build.process(['Gemfile.lock'])

      expect(status['state']).to eq('degraded')
      expect(status['reason']).to include('restart required')
    end
  end

  describe 'failure posture' do
    it 'degrades rather than crashing when a mid-edit syntax error breaks the reload' do
      # SyntaxError is a ScriptError, not a StandardError — rescuing only the
      # latter would let a half-typed file kill the daemon.
      allow(reloader).to receive(:reload!).and_raise(SyntaxError, 'unexpected end')
      touch('app/models/user.rb')

      result = nil
      expect { result = build.process(['app/models/user.rb']) }.not_to raise_error

      expect(result[:state]).to eq(:degraded)
      expect(result[:reason]).to include('SyntaxError')
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'degrades rather than crashing when extraction itself raises' do
      allow(extractor).to receive(:extract_changed).and_raise(StandardError, 'boom')
      touch('config/locales/en.yml')

      result = build.process(['config/locales/en.yml'])

      expect(result[:state]).to eq(:degraded)
      expect(result[:reason]).to include('boom')
    end

    it 'never advances the generation over work that did not land' do
      allow(extractor).to receive(:extract_changed).and_raise(StandardError, 'boom')
      touch('config/locales/en.yml')
      daemon = build

      before = daemon.generation.current.number
      daemon.process(['config/locales/en.yml'])

      expect(daemon.generation.current.number).to eq(before)
    end

    it 'keeps working after a failure once the cause is gone' do
      touch('app/models/user.rb')
      daemon = build

      allow(reloader).to receive(:reload!).and_raise(SyntaxError, 'unexpected end')
      expect(daemon.process(['app/models/user.rb'])[:state]).to eq(:degraded)

      allow(reloader).to receive(:reload!).and_return(true)
      expect(daemon.process(['app/models/user.rb'])[:state]).to eq(:running)
    end
  end

  describe 'storm handling' do
    it 'falls back to a full extraction above the threshold' do
      paths = Array.new(6) { |i| touch("app/services/svc_#{i}.rb") }

      result = build(full_extraction_threshold: 3).process(paths)

      expect(result[:action]).to eq(:full)
      expect(extractor).to have_received(:extract_all)
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'stays incremental at or below the threshold' do
      paths = Array.new(3) { |i| touch("app/services/svc_#{i}.rb") }

      result = build(full_extraction_threshold: 3).process(paths)

      expect(result[:action]).to eq(:incremental)
      expect(extractor).not_to have_received(:extract_all)
    end
  end

  describe 'publishing' do
    # The extractor owns the bump; the daemon reports it. Two bumps per cycle
    # would make the counter lie about how many times the index moved.
    it 'reports the generation the extraction published' do
      touch('config/locales/en.yml')
      daemon = build

      result = nil
      expect { result = daemon.process(['config/locales/en.yml']) }
        .to change { daemon.generation.current.number }.by(1)
      expect(result[:generation]).to eq(daemon.generation.current.number)
    end

    it 'does not mint a generation of its own when extraction publishes none' do
      allow(extractor).to receive(:extract_changed).and_return(['Thing'])
      touch('config/locales/en.yml')
      daemon = build

      expect { daemon.process(['config/locales/en.yml']) }
        .not_to(change { daemon.generation.current.number })
    end

    it 'leaves the generation alone when nothing was relevant' do
      touch('config/locales/en.yml')
      daemon = build
      daemon.process(['config/locales/en.yml'])

      expect { daemon.process(['README.md']) }.not_to(change { daemon.generation.current.number })
    end

    it 'reports a running state with the current generation' do
      touch('config/locales/en.yml')
      daemon = build
      daemon.process(['config/locales/en.yml'])

      expect(status).to include('state' => 'running', 'last_action' => 'incremental')
      expect(status['generation']).to eq(daemon.generation.current.number)
    end
  end

  describe '#run' do
    let(:fake_watcher) { FakeWatcher.new }

    # Delivers one canned batch, then lets the daemon stop it.
    class FakeWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
      attr_reader :batches, :stopped

      def initialize
        @batches = []
        @stopped = false
      end

      def queue(paths)
        @batches << paths
      end

      def start(&on_change)
        @batches.each do |batch|
          break if @stopped

          on_change.call(batch)
        end
      end

      def stop
        @stopped = true
      end
    end

    it 'processes batches the watcher delivers and reports why it ended' do
      touch('config/locales/en.yml')
      fake_watcher.queue(['config/locales/en.yml'])

      expect(build(watcher: fake_watcher).run).to eq(:stopped)
      expect(extractor).to have_received(:extract_changed)
    end

    it 'stops the watcher and reports a restart when boot state changes' do
      fake_watcher.queue(['config/initializers/redis.rb'])
      fake_watcher.queue(['config/locales/en.yml'])

      expect(build(watcher: fake_watcher).run).to eq(:restart_required)
      expect(fake_watcher.stopped).to be(true)
      # The second batch must not be processed after a restart is demanded.
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'leaves a stopped status behind so a reader knows nothing is maintaining the index' do
      build(watcher: fake_watcher).run

      expect(status['state']).to eq('stopped')
    end
  end
end
