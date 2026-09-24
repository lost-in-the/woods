# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'timeout'
require 'woods/watch/daemon'

RSpec.describe 'Managed watch daemon lifecycle' do
  # A real blocking backend with controllable registration and change delivery.
  class ControlledManagedWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
    attr_accessor :ready_callback
    attr_reader :registered

    def initialize
      @registered = Queue.new
      @ready = Queue.new
      @stopped = Queue.new
    end

    def start(&on_change)
      @on_change = on_change
      @registered << true
      @ready.pop
      ready_callback.call
      @stopped.pop
    end

    def ready!
      @ready << true
    end

    def change(path)
      @on_change.call([path])
    end

    def stop
      ready!
      @stopped << true
    end
  end

  let(:root) { Dir.mktmpdir('woods-managed-root') }
  let(:output_dir) { Dir.mktmpdir('woods-managed-index') }
  let(:events) { Queue.new }
  let(:watcher) { ControlledManagedWatcher.new }
  let(:extractor) { instance_spy('Woods::Extractor') }
  let(:generation) { Woods::Generation.new(output_dir: output_dir) }
  let(:reloader) { instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true) }
  let(:daemon) do
    Woods::Watch::Daemon.new(root: root, output_dir: output_dir, watcher: watcher,
                             extractor_factory: -> { extractor }, reloader: reloader, debounce: 0,
                             full_extraction_threshold: 0,
                             boot_snapshot: Woods::Watch::BootSnapshot.new(root: root),
                             lifecycle: ->(event, **fields) { events << [event, fields] }, conservative_claims: true)
  end

  before do
    FileUtils.mkdir_p(File.join(root, 'app/models'))
    File.write(File.join(root, 'app/models/user.rb'), 'class User; end')
    allow(extractor).to receive(:extract_all) { publish_index }
    allow(extractor).to receive(:extract_changed) { publish_index && ['User'] }
  end

  after do
    daemon.stop
    @thread&.join(5) || @thread&.kill&.join
    FileUtils.rm_rf([root, output_dir])
  end

  def next_event
    Timeout.timeout(5) { events.pop }
  end

  def publish_index
    File.write(File.join(output_dir, 'manifest.json'), '{}')
    generation.bump!(reason: 'managed test')
  end

  def start_daemon
    @thread = Thread.new { daemon.run }
    Timeout.timeout(5) { watcher.registered.pop }
  end

  it 'reports backend readiness and completed publication at their actual boundaries' do
    extracting = Queue.new
    finish = Queue.new
    allow(extractor).to receive(:extract_all) do
      extracting << true
      finish.pop
      publish_index
    end

    start_daemon
    expect(events).to be_empty # daemon already wrote its early running status
    watcher.ready!
    expect(next_event).to eq([:backend_ready, {}])
    Timeout.timeout(5) { extracting.pop }
    expect(events).to be_empty # running extraction is not completed startup
    finish << true
    expect(next_event).to eq([:startup, { state: 'ready', generation: 1, reason: 'reconciled' }])
  ensure
    finish << true
  end

  it 'reports degraded startup and later recovery without leaking exception details' do
    allow(extractor).to receive(:extract_all).and_raise(StandardError, 'private application value')
    start_daemon
    watcher.ready!
    expect(next_event).to eq([:backend_ready, {}])
    expect(next_event).to eq([:startup, { state: 'degraded', generation: 0, reason: 'startup_failed' }])

    daemon.instance_variable_get(:@drain_mutex).synchronize {} # initial startup has relinquished its drain
    allow(extractor).to receive(:extract_all) { publish_index }
    watcher.change(File.join(root, 'app/models/user.rb'))
    expect(next_event).to eq([:startup, { state: 'ready', generation: 1, reason: 'reconciled' }])
  end

  it 'does not report unchanged startup ready when no index was produced' do
    FileUtils.rm_f(File.join(root, 'app/models/user.rb'))
    start_daemon
    watcher.ready!
    expect(next_event).to eq([:backend_ready, {}])
    expect(next_event).to eq([:startup, { state: 'degraded', generation: 0, reason: 'no_index' }])
  end

  it 'does not mistake a generation marker without a manifest for a usable publication' do
    FileUtils.rm_f(File.join(root, 'app/models/user.rb'))
    generation.bump!(reason: 'missing payload', payload: 'payloads/missing')
    allow(extractor).to receive(:extract_all) { generation.bump!(reason: 'still missing manifest') }
    start_daemon
    watcher.ready!
    expect(next_event).to eq([:backend_ready, {}])
    expect(next_event).to eq([:startup, { state: 'degraded', generation: 2, reason: 'no_index' }])
    expect(extractor).to have_received(:extract_all).once
  end

  it 'does not overwrite an existing foreign owner, even with the raw force flag' do
    claim = File.join(output_dir, Woods::Watch::Daemon::CLAIM_FILENAME)
    content = JSON.generate(pid: Process.pid, host: 'different-container')
    File.write(claim, content)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WOODS_IGNORE_WATCH').and_return('1')

    expect(daemon.run).to eq(:already_running)
    expect(File.read(claim)).to eq(content)
    expect(events).to be_empty
    expect(File.exist?(File.join(output_dir, Woods::Watch::Status::FILENAME))).to be(false)
  end

  [{ pid: 22 }, [], { host: Woods::Watch::Status.host_identity, pid: 'unknown' }].each do |claim_data|
    it "refuses unknown ownership #{claim_data.inspect}" do
      claim = File.join(output_dir, Woods::Watch::Daemon::CLAIM_FILENAME)
      File.write(claim, JSON.generate(claim_data))

      expect(daemon.run).to eq(:already_running)
      expect(JSON.parse(File.read(claim))).to eq(JSON.parse(JSON.generate(claim_data)))
    end
  end

  it 'reclaims a verified dead same-host owner without weakening the foreign guard' do
    pid = Process.spawn(RbConfig.ruby, '-e', 'exit 0')
    Process.wait(pid)
    claim = File.join(output_dir, Woods::Watch::Daemon::CLAIM_FILENAME)
    File.write(claim, JSON.generate(pid: pid, host: Woods::Watch::Status.host_identity))

    start_daemon
    watcher.ready!
    expect(next_event.first).to eq(:backend_ready)
    expect(next_event.last[:state]).to eq('ready')
  end
end
