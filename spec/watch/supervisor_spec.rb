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
