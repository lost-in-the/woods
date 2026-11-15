# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'
require 'woods/watch/daemon'

# One burst of changes (a checkout, a pull, a schema dump) costs at most one
# full extraction: no full run starts in a process whose boot no longer matches
# the restart inputs on disk, a restart input rewritten with the bytes the boot
# read demands no restart, and paths whose bytes the published generation
# already captured never make another storm.
RSpec.describe 'Watch daemon: one full extraction per burst' do
  let(:root) { Dir.mktmpdir('woods_burst_root') }
  let(:output_dir) { Dir.mktmpdir('woods_burst_out') }
  let(:extractor) do
    instance_spy('Woods::Extractor').tap do |double|
      allow(double).to receive(:extract_changed) { publish(capture, 'incremental') && ['Thing'] }
      allow(double).to receive(:extract_all) { publish(capture, 'full') && {} }
    end
  end
  let(:reloader) do
    instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true, once_owned?: false)
  end

  after { FileUtils.rm_rf([root, output_dir]) }

  def build(**overrides)
    Woods::Watch::Daemon.new(
      output_dir: output_dir, root: root, extractor_factory: -> { extractor }, reloader: reloader,
      debounce: 0, catch_up: false, full_extraction_threshold: 3,
      boot_snapshot: Woods::Watch::BootSnapshot.new(root: root), **overrides
    )
  end

  # The real extractor captures source bytes when it starts and publishes
  # them when it finishes, so a stub that captured at publication would make
  # an edit during the run look covered.
  def capture
    key = Woods::SourceInputs::PrivateKey.new(output_dir: output_dir, create: true)
    scopes = Woods::SourceInputs::Scopes.new(extra_roots: [])
    Woods::SourceInputs::Scanner.new(root: root, output_dir: output_dir, key: key, scopes: scopes).call
  end

  def publish(snapshot, reason)
    generation = Woods::Generation.new(output_dir: output_dir)
    scopes = snapshot.fetch('scope_paths').transform_values do |paths|
      paths.to_h { |path| [path, snapshot.fetch('files').fetch(path)] }
    end
    manifest = Woods::SourceInputs::Manifest.build(snapshot: snapshot, scopes: scopes, boot_verified: true,
                                                   generation: generation.current.number + 1)
    File.write(File.join(output_dir, 'source_inputs.json'), JSON.generate(manifest.data))
    generation.bump!(reason: reason)
  end

  def write(relative, body = "# #{relative}\n")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # Same bytes, new inode and timestamps: what `db:prepare` dumping an
  # unchanged schema, a stash round trip or a checkout of the same blob does.
  def rewrite_unchanged(path)
    bytes = File.binread(path)
    File.unlink(path)
    File.binwrite(path, bytes)
    future = Time.now + 5
    File.utime(future, future, path)
    path
  end

  def live(daemon, paths)
    daemon.send(:enqueue, paths)
    daemon.send(:drain)
  end

  def pending_file
    JSON.parse(File.read(File.join(output_dir, 'watch_pending.json')))
  end

  def generation
    Woods::Generation.new(output_dir: output_dir).current.number
  end

  # Polling shape: the poll thread runs each drain itself, so a batch arrives
  # only after the previous cycle returned, holding everything since the last
  # scan, including files written before that cycle's extraction started.
  class SerialWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
    # The first poll follows the baseline, which the daemon awaits before its
    # startup reconciliation.
    attr_writer :ready_callback

    def initialize(*batches)
      @batches = batches
      @stopped = false
    end

    def start(&on_change)
      @ready_callback&.call
      sleep(0.05)
      @batches.each { |batch| on_change.call(batch) unless @stopped }
      sleep(0.01) until @stopped
    end

    def stop
      @stopped = true
    end
  end

  # Hands the daemon's callback to the example, like a native backend that
  # delivers from its own thread whenever a file changes.
  class CallbackWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
    attr_reader :on_change
    attr_writer :ready_callback

    def initialize
      @stopped = false
    end

    def start(&on_change)
      @on_change = on_change
      @ready_callback&.call
      sleep(0.01) until @stopped
    end

    def stop
      @stopped = true
    end
  end

  # A fresh process after exit 75: new boot snapshot, startup catch-up, no
  # live events. Stops once its startup reconciliation has drained.
  def successor
    daemon = build(watcher: SerialWatcher.new, catch_up: true)
    thread = Thread.new { daemon.run }
    Timeout.timeout(5) { sleep(0.01) until daemon.instance_variable_get(:@lifecycle_started) }
    daemon.stop unless thread.join(0.3)
    Timeout.timeout(5) { thread.value }
  end

  before do
    write('app/models/base.rb')
    write('config/initializers/widget.rb', "Widget.mode = :a\n")
    write('db/schema.rb', "ActiveRecord::Schema.define(version: 1) {}\n")
    publish(capture, 'seed')
  end

  describe 'a restart input rewritten with the bytes the boot read' do
    it 'neither restarts nor extracts for an unchanged initializer' do
      daemon = build
      rewrite_unchanged(File.join(root, 'config/initializers/widget.rb'))

      live(daemon, ['config/initializers/widget.rb'])

      expect(daemon.instance_variable_get(:@stop_reason)).to be_nil
      expect(extractor).not_to have_received(:extract_all)
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'neither restarts nor extracts for a schema dump that changed nothing' do
      daemon = build
      rewrite_unchanged(File.join(root, 'db/schema.rb'))

      live(daemon, ['db/schema.rb'])

      expect(daemon.instance_variable_get(:@stop_reason)).to be_nil
      expect(extractor).not_to have_received(:extract_all)
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'neither restarts nor extracts for an unchanged config helper this process loaded at boot' do
      helper = write('config/time_zone.rb', "Rails.application.config.time_zone = 'UTC'\n")
      daemon = build
      daemon.loaded_boot_paths = ['config/time_zone.rb']
      rewrite_unchanged(helper)

      live(daemon, [helper])

      expect(daemon.instance_variable_get(:@stop_reason)).to be_nil
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'neither restarts nor extracts for an initializer created and deleted before its event was handled' do
      daemon = build
      transient = write('config/initializers/transient.rb')
      File.unlink(transient)

      live(daemon, [transient])

      expect(daemon.instance_variable_get(:@stop_reason)).to be_nil
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'still extracts the other paths of the batch it arrived with' do
      daemon = build
      rewrite_unchanged(File.join(root, 'db/schema.rb'))
      model = write('app/models/base.rb', "class Base; end\n")

      live(daemon, ['db/schema.rb', model])

      expect(daemon.instance_variable_get(:@stop_reason)).to be_nil
      expect(extractor).to have_received(:extract_changed).with(array_including(model))
    end

    it 'still restarts when the initializer bytes changed' do
      daemon = build
      write('config/initializers/widget.rb', "Widget.mode = :b\n")

      live(daemon, ['config/initializers/widget.rb'])

      expect(daemon.instance_variable_get(:@stop_reason)).to eq(:restart_required)
      expect(extractor).not_to have_received(:extract_all)
    end

    it 'still reloads routes reverted to their boot bytes after an edit reached the index' do
      routes = write('config/routes.rb', "Rails.application.routes.draw {}\n")
      daemon = build
      write('config/routes.rb', "Rails.application.routes.draw { root 'a#b' }\n")
      live(daemon, [routes])
      write('config/routes.rb', "Rails.application.routes.draw {}\n")

      live(daemon, [routes])

      expect(extractor).to have_received(:extract_changed).twice
    end

    it 'reconciles a rewrite made during boot with the one startup full extraction' do
      initializer = File.join(root, 'config/initializers/widget.rb')
      write('config/initializers/widget.rb', "Widget.mode = :b\n")
      snapshot = Woods::Watch::BootSnapshot.new(root: root)
      rewrite_unchanged(initializer)
      File.write(File.join(output_dir, 'watch_pending.json'), JSON.generate([initializer]))

      daemon = build(watcher: SerialWatcher.new, catch_up: true, boot_snapshot: snapshot)
      thread = Thread.new { daemon.run }
      Timeout.timeout(5) { sleep(0.01) until daemon.instance_variable_get(:@lifecycle_started) }
      daemon.stop unless thread.join(0.3)

      expect(Timeout.timeout(5) { thread.value }).to eq(:stopped)
      expect(extractor).to have_received(:extract_all).once
    end

    it 'keeps a restarted daemon up when the initializer is rewritten unchanged during its startup full run' do
      initializer = write('config/initializers/widget.rb', "Widget.mode = :b\n")
      File.write(File.join(output_dir, 'watch_pending.json'), JSON.generate([initializer]))
      watcher = CallbackWatcher.new
      allow(extractor).to receive(:extract_all) do
        snapshot = capture
        rewrite_unchanged(initializer)
        Thread.new { watcher.on_change.call([initializer]) }.join
        publish(snapshot, 'full') && {}
      end
      daemon = build(watcher: watcher, catch_up: true)
      thread = Thread.new { daemon.run }
      Timeout.timeout(5) { sleep(0.01) until daemon.instance_variable_get(:@lifecycle_started) || !thread.alive? }
      daemon.stop unless thread.join(0.3)

      expect(Timeout.timeout(5) { thread.value }).to eq(:stopped)
      expect(extractor).to have_received(:extract_all).once
      expect(generation).to eq(2)
      expect(pending_file).to be_empty
    end
  end

  describe 'a restart input changed on disk before its event arrived' do
    it 'restarts instead of starting a storm full extraction' do
      daemon = build
      models = Array.new(4) { |i| write("app/models/m#{i}.rb") }
      initializer = write('config/initializers/widget.rb', "Widget.mode = :b\n")

      result = daemon.process(models)

      expect(result[:action]).to eq(:restart)
      expect(result[:reason]).to include('config/initializers/widget.rb')
      expect(extractor).not_to have_received(:extract_all)
      expect(daemon.send(:drain_with, [])).to include(initializer, *models)
    end

    it 'restarts instead of escalating a refused incremental to a full extraction' do
      daemon = build
      write('config/initializers/widget.rb', "Widget.mode = :b\n")
      allow(extractor).to receive(:extract_changed)
        .and_raise(Woods::ExtractionConfigChanged, 'Extraction configuration differs (settings_readers)')

      result = daemon.process([write('app/models/base.rb', "class Base; end\n")])

      expect(result[:action]).to eq(:restart)
      expect(extractor).not_to have_received(:extract_all)
    end

    it 'restarts instead of running the startup full extraction' do
      initializer = write('config/initializers/widget.rb', "Widget.mode = :b\n")
      File.write(File.join(output_dir, 'watch_pending.json'), JSON.generate([initializer]))
      # Edited after startup classified the batch, while the cycle takes the
      # writer lock: no event and no earlier check can have seen it.
      lock = double('lock', release: nil, touch: nil)
      allow(lock).to receive(:acquire) { write('config/initializers/widget.rb', "Widget.mode = :c\n") && true }
      daemon = build(watcher: SerialWatcher.new, catch_up: true, lock: lock)

      expect(Timeout.timeout(5) { daemon.run }).to eq(:restart_required)
      expect(extractor).not_to have_received(:extract_all)
      expect(pending_file).to include(initializer)
    end

    it 'runs one full extraction across the restart for a burst delivered in three polls' do
      first = Array.new(4) { |i| File.join(root, "app/models/m#{i}.rb") }
      second = Array.new(4) { |i| File.join(root, "app/models/n#{i}.rb") }
      initializer = File.join(root, 'config/initializers/widget.rb')
      daemon = build(watcher: SerialWatcher.new(first, second, [initializer]))
      (first + second).each { |path| write(path.delete_prefix("#{root}/")) }
      write('config/initializers/widget.rb', "Widget.mode = :b\n")

      expect(Timeout.timeout(5) { daemon.run }).to eq(:restart_required)
      expect(pending_file).to include(initializer, *first)
      expect(successor).to eq(:stopped)
      expect(extractor).to have_received(:extract_all).once
      expect(generation).to eq(2)
    end

    it 'keeps the storm full extraction without a boot snapshot to compare against' do
      daemon = build(boot_snapshot: nil)
      write('config/initializers/widget.rb', "Widget.mode = :b\n")

      result = daemon.process(Array.new(4) { |i| write("app/models/m#{i}.rb") })

      expect(result[:action]).to eq(:full)
    end
  end

  describe 'a storm delivered after the full run that already captured it' do
    it 're-extracts the late batch incrementally instead of a second full run' do
      daemon = build
      first = Array.new(4) { |i| write("app/models/m#{i}.rb") }
      second = Array.new(4) { |i| write("app/models/n#{i}.rb") }

      expect(daemon.process(first)[:action]).to eq(:full)
      result = daemon.process(second)

      expect(result[:action]).to eq(:incremental)
      expect(extractor).to have_received(:extract_all).once
      expect(extractor).to have_received(:extract_changed).with(match_array(second))
    end

    it 'runs another full extraction for a storm edited after the full run captured it' do
      daemon = build
      first = Array.new(4) { |i| write("app/models/m#{i}.rb") }
      second = Array.new(4) { |i| write("app/models/n#{i}.rb") }
      allow(extractor).to receive(:extract_all) do
        snapshot = capture
        second.each { |path| File.write(path, "# edited while the full run extracts\n") }
        publish(snapshot, 'full') && {}
      end

      daemon.process(first)
      result = daemon.process(second)

      expect(result[:action]).to eq(:full)
      expect(extractor).to have_received(:extract_all).twice
    end

    it 'retries a storm whose full run failed as a full run' do
      daemon = build
      storm = Array.new(4) { |i| write("app/models/m#{i}.rb") }
      allow(extractor).to receive(:extract_all).and_raise(StandardError, 'interrupted')
      expect(daemon.process(storm)[:state]).to eq(:degraded)

      allow(extractor).to receive(:extract_all) { publish(capture, 'full') && {} }
      result = daemon.process([])

      expect(result[:action]).to eq(:full)
      expect(extractor).to have_received(:extract_all).twice
    end
  end
end
