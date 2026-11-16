# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'
require 'woods/watch/daemon'

# No published generation means the startup run is a full extraction, whatever
# the file count: an incremental run refuses without a baseline, so anything
# else leaves the watcher degraded with no index at all.
RSpec.describe 'Watch daemon: the first index' do
  let(:root) { Dir.mktmpdir('woods_first_root') }
  let(:output_dir) { Dir.mktmpdir('woods_first_out') }
  let(:no_baseline) { Woods::ExtractionError.new('No baseline index found') }
  let(:extractor) do
    instance_spy('Woods::Extractor').tap do |double|
      # The real incremental run refuses without a baseline (Extractor#ensure_incremental_baseline!).
      allow(double).to receive(:extract_changed) do
        raise no_baseline if generation.zero?

        Woods::Generation.new(output_dir: output_dir).bump!(reason: 'incremental') && ['Thing']
      end
      allow(double).to receive(:extract_all) { Woods::Generation.new(output_dir: output_dir).bump!(reason: 'full') && {} }
    end
  end
  let(:reloader) do
    instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true, once_owned?: false)
  end

  after { FileUtils.rm_rf([root, output_dir]) }

  # Hands the callback to the example, like a native backend.
  class FirstIndexWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
    attr_reader :on_change
    attr_writer :ready_callback

    def start(&on_change)
      @on_change = on_change
      @ready_callback&.call
      sleep(0.01) until @stopped
    end

    def stop
      @stopped = true
    end
  end

  def generation
    Woods::Generation.new(output_dir: output_dir).current.number
  end

  def write(relative, body = "# #{relative}\n")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def daemon(watcher = FirstIndexWatcher.new)
    Woods::Watch::Daemon.new(output_dir: output_dir, root: root, extractor_factory: -> { extractor },
                             reloader: reloader, debounce: 0, catch_up: true, watcher: watcher,
                             boot_snapshot: Woods::Watch::BootSnapshot.new(root: root))
  end

  def run_startup(watch = daemon)
    thread = Thread.new { watch.run }
    Timeout.timeout(5) { sleep(0.01) until watch.instance_variable_get(:@lifecycle_started) || !thread.alive? }
    watch.stop unless thread.join(0.2)
    Timeout.timeout(5) { thread.value }
  end

  def status
    JSON.parse(Woods::AtomicFile.read(File.join(output_dir, Woods::Watch::Status::FILENAME)))
  end

  [0, 4, 50, 51].each do |count|
    it "publishes a first generation by one full extraction over #{count} actionable file(s)" do
      Array.new(count) { |i| write("app/models/model_#{i}.rb") }

      expect(run_startup).to eq(:stopped)
      expect(extractor).to have_received(:extract_all).once
      expect(extractor).not_to have_received(:extract_changed)
      expect(generation).to eq(1)
    end
  end

  it 'publishes a first generation over a tree with nothing actionable in it' do
    write('README.md')

    run_startup

    expect(extractor).to have_received(:extract_all).once
    expect(generation).to eq(1)
  end

  it 'publishes a first generation over leftovers of a run that never published' do
    write('app/models/model.rb')
    FileUtils.mkdir_p(File.join(output_dir, 'payloads/gen-1'))
    FileUtils.mkdir_p(File.join(output_dir, 'payloads/.stage-1-killed'))

    run_startup

    expect(extractor).to have_received(:extract_all).once
    expect(generation).to eq(1)
  end

  it 'does not start a full extraction over a corrupt generation marker, and says how to recover' do
    write('app/models/model.rb')
    File.write(File.join(output_dir, Woods::Generation::FILENAME), '{"number": ')
    watch = daemon

    watch.send(:catch_up)

    expect(extractor).not_to have_received(:extract_all)
    expect(extractor).not_to have_received(:extract_changed)
    expect(status).to include('state' => 'degraded')
    expect(status['reason']).to include('generation.json', Woods::Generation::RESTORE_ADVICE)
  end

  # Promotion moves the stage to gen-<n> before the marker is written, so a
  # failed publish leaves the newest directory unpublished.
  it 'does not send a corrupt marker back to the unpublished newest payload a failed publish left' do
    write('app/models/model.rb')
    %w[gen-1 gen-2 gen-3].each { |name| FileUtils.mkdir_p(File.join(output_dir, 'payloads', name)) }
    File.write(File.join(output_dir, Woods::Generation::FILENAME), '{"number": ')
    watch = daemon

    watch.send(:catch_up)

    expect(status['reason']).not_to include('newest retained')
    expect(status['reason']).to include('except possibly the newest', 'name the second newest')
  end

  it 'retries a first full extraction that failed, as a full extraction' do
    write('app/models/model.rb')
    watch = daemon
    allow(extractor).to receive(:extract_all).and_raise(StandardError, 'interrupted')
    watch.send(:catch_up)
    expect(generation).to eq(0)

    allow(extractor).to receive(:extract_all) { Woods::Generation.new(output_dir: output_dir).bump!(reason: 'full') && {} }
    watch.send(:drain)

    expect(extractor).to have_received(:extract_all).twice
    expect(extractor).not_to have_received(:extract_changed)
    expect(generation).to eq(1)
  end

  it 'indexes a live edit that arrives while the first full extraction runs' do
    write('app/models/model.rb')
    watcher = FirstIndexWatcher.new
    live = nil
    allow(extractor).to receive(:extract_all) do
      live = write('app/models/live.rb')
      Thread.new { watcher.on_change.call([live]) }.join
      Woods::Generation.new(output_dir: output_dir).bump!(reason: 'full') && {}
    end

    run_startup(daemon(watcher))

    expect(extractor).to have_received(:extract_all).once
    expect(extractor).to have_received(:extract_changed).with(array_including(live))
    expect(generation).to eq(2)
  end
end
