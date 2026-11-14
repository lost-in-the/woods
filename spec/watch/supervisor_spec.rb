# frozen_string_literal: true

require 'spec_helper'
require 'woods/watch/supervisor'
require 'tmpdir'
require 'timeout'
require 'stringio'

RSpec.describe Woods::Watch::Supervisor do
  around do |example|
    Dir.mktmpdir('woods supervisor ') do |root|
      @root = root
      example.run
    end
  end

  after do
    @supervisor&.stop
    @thread&.join(5)
  end

  def launch(body, **options)
    script = <<~RUBY
      require #{File.expand_path('../../lib/woods/watch/managed_child', __dir__).inspect}
      child = Woods::Watch::ManagedChild.from_env
      #{body}
    RUBY
    @log = StringIO.new
    @supervisor = described_class.new(command: [Gem.ruby, '-e', script], root: @root,
                                      logger: @log, shutdown_timeout: 0.1, retry_delays: [0.02], **options)
    @thread = Thread.new { @supervisor.run }
  end

  def eventually
    Timeout.timeout(5) { sleep 0.02 until yield }
  rescue Timeout::Error
    raise "Supervisor fixture timed out:\n#{@log.string}"
  end

  def handshake
    <<~RUBY
      child.call(:task_loaded, woods_version: '2.0.0.beta4')
      child.call(:identity, root: Dir.pwd, index: File.join(Dir.pwd, 'index'))
      child.call(:backend_ready)
    RUBY
  end

  ['', " \t "].each do |blank|
    it "accepts a blank idle TTL #{blank.inspect} before starting its child" do
      expect do
        described_class.new(command: [Gem.ruby], root: @root, env: { 'WOODS_WATCH_IDLE_TIMEOUT' => blank })
      end.not_to raise_error
    end
  end

  it 'absorbs exit 75 and boots a fresh task without ending its owner' do
    launch(<<~RUBY)
      #{handshake}
      unless File.exist?('restarted')
        File.write('restarted', 'yes')
        child.call(:terminal, reason: 'restart_required')
        exit 75
      end
      child.call(:startup, state: 'ready', generation: 2, reason: 'reconciled')
      sleep 30
    RUBY
    eventually { @supervisor.state == 'ready' }
    expect(@thread).to be_alive
    expect(@supervisor.attempts).to eq(2)
  end

  it 'retries boot failures but parks an incompatible successful command' do
    launch("exit(File.exist?('once') ? 0 : (File.write('once', 'yes'); 1))")
    eventually { @supervisor.state == 'parked' }
    expect(@supervisor.attempts).to eq(2)
    expect(@thread).to be_alive
  end

  it 'does not mistake task boot or backend startup for a reconciled index' do
    launch("#{handshake}\nsleep 30", boot_timeout: 2)
    eventually { @supervisor.state == 'reconciling' }
    # Move only the boot clock past its deadline once identity has resolved.
    @supervisor.instance_variable_set(:@started_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10)
    sleep 0.15
    expect(@supervisor.state).to eq('reconciling')
    expect(@supervisor.attempts).to eq(1)
  end

  it 'parks a duplicate instead of taking over when its owner later disappears' do
    launch("#{handshake}\nchild.call(:terminal, reason: 'already_running'); exit 0")
    eventually { @supervisor.state == 'parked' }
    expect(@log.string).to include('already_running')
    expect(@supervisor.attempts).to eq(1)
  end

  describe 'parking behind a claim (#1078)' do
    let(:token) { 'c' * 64 }

    def park_behind(host)
      claim = JSON.generate(pid: 57, host: host, lease_version: 2, token: token, lease_id: 'e' * 32)
      launch(<<~RUBY)
        #{handshake}
        Dir.mkdir('index') unless Dir.exist?('index')
        File.write(File.join('index', 'watch_claim.json'), #{claim.inspect})
        child.call(:terminal, reason: 'already_running')
        exit 0
      RUBY
      # The advice follows the parked record, so its line means both are written.
      eventually { @log.string.include?('--recover-claim') }
      File.join(File.realpath(@root), 'index')
    end

    def supervision_record
      JSON.parse(File.read(Dir[File.join(@root, 'index/watch_supervisors/*.json')].first))
    end

    it 'names the owner host and the exact recovery command for a claim from another host' do
      index = park_behind('retired-container')

      expect(@log.string).to include('owned by host retired-container (pid 57)')
      expect(@log.string).to include('confirm that host or container no longer exists')
      expect(@log.string)
        .to include("woods-watch --recover-claim #{index} --claim-token <token from #{index}/watch_claim.json>")
      expect(@log.string).not_to include(token)
      expect(supervision_record).to include('state' => 'parked', 'reason' => 'owner_on_other_host')
    end

    it 'tells a same-host duplicate to stop its owner before recovering' do
      index = park_behind(Woods::Watch::Status.host_identity)

      expect(@log.string).to include('owned by pid 57 on this host')
      expect(@log.string).to include("woods-watch --recover-claim #{index}")
      expect(@log.string).not_to include(token)
      expect(supervision_record).to include('state' => 'parked', 'reason' => 'already_running')
    end
  end

  it 'bounds an initializer hang and retries after its boot deadline' do
    launch("child.call(:task_loaded, woods_version: '2.0.0.beta4'); sleep 30", boot_timeout: 0.1)
    eventually { @supervisor.attempts >= 2 }
    expect(@log.string).to include('boot_timeout')
  end

  it 'refuses managed idle timeout, including zero, before starting any process' do
    expect do
      described_class.new(command: [Gem.ruby], root: @root, env: { 'WOODS_WATCH_IDLE_TIMEOUT' => '0' })
    end.to raise_error(ArgumentError, /must be unset/)
  end

  it 'keeps its owner alive when its diagnostic record becomes corrupt' do
    launch("#{handshake}\nchild.call(:startup, state: 'ready', generation: 1, reason: 'reconciled'); sleep 30")
    # The in-memory state changes before its forced status write. Wait for that
    # publication so it cannot overwrite the corruption this test introduces.
    path = nil
    eventually do
      path = Dir[File.join(@root, 'index/watch_supervisors/*.json')].first
      path && JSON.parse(File.read(path))['state'] == 'ready'
    end
    File.write(path, '{corrupt')
    @supervisor.send(:heartbeat, force: true)

    expect(@thread).to be_alive
    expect(@supervisor.state).to eq('ready')
    expect(@log.string).to include('cannot write supervision status (ArgumentError)')
    @supervisor.stop
    expect(@thread.join(5).value).to eq(0)
  end

  it 'does not assign a new unresolved boot to the preceding index identity' do
    launch(<<~RUBY)
      if File.exist?('attempted')
        sleep 30
      else
        #{handshake}
        child.call(:startup, state: 'ready', generation: 1, reason: 'reconciled')
        File.write('attempted', 'yes')
        exit 1
      end
    RUBY
    eventually { @supervisor.attempts == 2 }
    path = Dir[File.join(@root, 'index/watch_supervisors/*.json')].first
    before = File.read(path)
    expect(JSON.parse(before)['state']).to eq('stopped')
    @supervisor.send(:heartbeat, force: true)
    expect(File.read(path)).to eq(before)
  end
end
