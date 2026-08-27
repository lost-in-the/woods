# frozen_string_literal: true

require 'spec_helper'
require 'woods/watch/watcher'

# {.build} is the seam between the two backends and the daemon that depends on
# them. Its failure mode is silent — a daemon that reports running and never
# fires — so the selection rules (listen when usable, polling in containers or
# on demand) and the WOODS_WATCH_POLL escape hatch are asserted directly here.
RSpec.describe Woods::Watch::Watcher do
  let(:logger) { double('Logger', info: nil, warn: nil) }
  let(:root) { Dir.mktmpdir('woods_watcher_build') }

  after { FileUtils.rm_rf(root) }

  # Both backend constants are stubbed so no example depends on whether the
  # `listen` gem happens to be in the current bundle (it is not in the base
  # one, and Rails apps usually have it — the specs must pass in both worlds).
  # The fakes mirror the real constructors' kwargs-only signatures.
  let(:listen_watcher_class) do
    stub_const('Woods::Watch::ListenWatcher', Class.new do
      def initialize(**); end
    end)
  end
  let(:polling_watcher_class) do
    stub_const('Woods::Watch::PollingWatcher', Class.new do
      def initialize(**); end
    end)
  end

  def stub_env(key, value)
    allow(ENV).to receive(:key?).and_call_original
    allow(ENV).to receive(:key?).with(key).and_return(!value.nil?)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(key).and_return(value) unless value.nil?
  end

  def stub_container_markers(dockerenv: false, containerenv: false)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with('/.dockerenv').and_return(dockerenv)
    allow(File).to receive(:exist?).with('/run/.containerenv').and_return(containerenv)
  end

  def listen_available
    allow(Woods::Watch::Watcher).to receive(:require).with('listen').and_return(true)
  end

  def listen_unavailable
    allow(Woods::Watch::Watcher).to receive(:require).with('listen')
                                                     .and_raise(LoadError, 'cannot load such file -- listen')
  end

  describe '.build' do
    it 'prefers the listen backend when the listen gem loads' do
      listen_available
      listen_instance = listen_watcher_class.new
      allow(listen_watcher_class).to receive(:new).and_return(listen_instance)

      watcher = described_class.build(root: root, logger: logger)

      expect(watcher).to be(listen_instance)
      expect(listen_watcher_class).to have_received(:new)
        .with(root: root, ignored: described_class::DEFAULT_IGNORED_DIRECTORIES)
      expect(logger).to have_received(:info).with(/native FS events/)
    end

    it 'falls back to polling when the listen gem is unavailable' do
      listen_unavailable
      polling_instance = polling_watcher_class.new
      allow(polling_watcher_class).to receive(:new).and_return(polling_instance)

      watcher = described_class.build(root: root, logger: logger)

      expect(watcher).to be(polling_instance)
      expect(logger).to have_received(:info).with(/listen gem not available/)
      expect(logger).to have_received(:info).with(/polling every 1\.0s/)
    end

    it 'never reaches for listen when force_polling is requested' do
      listen_available
      allow(listen_watcher_class).to receive(:new)
      polling_instance = polling_watcher_class.new
      allow(polling_watcher_class).to receive(:new).and_return(polling_instance)

      watcher = described_class.build(root: root, force_polling: true, logger: logger)

      expect(watcher).to be(polling_instance)
      expect(Woods::Watch::Watcher).not_to have_received(:require)
      expect(listen_watcher_class).not_to have_received(:new)
    end

    # The container heuristic exists because native FS events do not cross
    # bind mounts reliably: a daemon that selects listen inside a container
    # reports running and never fires. Presence of the marker must therefore
    # beat listen being available.
    it 'forces polling inside a container even when listen is available' do
      listen_available
      stub_container_markers(dockerenv: true)
      polling_instance = polling_watcher_class.new
      allow(polling_watcher_class).to receive(:new).and_return(polling_instance)

      watcher = described_class.build(root: root, logger: logger)

      expect(watcher).to be(polling_instance)
      expect(Woods::Watch::Watcher).not_to have_received(:require)
    end

    it 'lets WOODS_WATCH_POLL=0 override container detection' do
      listen_available
      stub_env('WOODS_WATCH_POLL', '0')
      stub_container_markers(dockerenv: true)
      listen_instance = listen_watcher_class.new
      allow(listen_watcher_class).to receive(:new).and_return(listen_instance)

      watcher = described_class.build(root: root, logger: logger)

      expect(watcher).to be(listen_instance)
    end

    it 'forces polling when WOODS_WATCH_POLL is set to anything but 0' do
      listen_available
      stub_env('WOODS_WATCH_POLL', '1')
      stub_container_markers
      polling_instance = polling_watcher_class.new
      allow(polling_watcher_class).to receive(:new).and_return(polling_instance)

      watcher = described_class.build(root: root, logger: logger)

      expect(watcher).to be(polling_instance)
    end

    it 'passes ignored and poll_interval through to the polling backend' do
      listen_unavailable
      allow(polling_watcher_class).to receive(:new).and_return(polling_watcher_class.new)

      described_class.build(root: root, ignored: %w[custom], poll_interval: 2.5, logger: logger)

      expect(polling_watcher_class).to have_received(:new)
        .with(root: root, ignored: %w[custom], interval: 2.5)
    end

    it 'logs the polling interval it selected' do
      listen_unavailable
      allow(polling_watcher_class).to receive(:new)

      described_class.build(root: root, poll_interval: 2.5, logger: logger)

      expect(logger).to have_received(:info).with(/polling every 2\.5s/)
    end
  end

  describe '.containerized?' do
    it 'is false when WOODS_WATCH_POLL=0, even with container markers present' do
      stub_env('WOODS_WATCH_POLL', '0')
      stub_container_markers(dockerenv: true, containerenv: true)

      expect(described_class.containerized?).to be(false)
    end

    it 'is true when WOODS_WATCH_POLL is set to anything but 0' do
      stub_env('WOODS_WATCH_POLL', 'yes')
      stub_container_markers

      expect(described_class.containerized?).to be(true)
    end

    it 'is true when /.dockerenv exists' do
      stub_env('WOODS_WATCH_POLL', nil)
      stub_container_markers(dockerenv: true)

      expect(described_class.containerized?).to be(true)
    end

    it 'is true when /run/.containerenv exists' do
      stub_env('WOODS_WATCH_POLL', nil)
      stub_container_markers(containerenv: true)

      expect(described_class.containerized?).to be(true)
    end

    it 'is false on a bare host' do
      stub_env('WOODS_WATCH_POLL', nil)
      stub_container_markers

      expect(described_class.containerized?).to be(false)
    end

    it 'is false when probing the filesystem raises' do
      stub_env('WOODS_WATCH_POLL', nil)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/.dockerenv').and_raise(StandardError, 'stat failed')

      expect(described_class.containerized?).to be(false)
    end
  end
end
