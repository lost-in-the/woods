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

  def launch(body, flags: [], **options)
    script = <<~RUBY
      require #{File.expand_path('../../lib/woods/watch/managed_child', __dir__).inspect}
      child = Woods::Watch::ManagedChild.from_env
      #{body}
    RUBY
    @log = StringIO.new
    @supervisor = described_class.new(command: [Gem.ruby, *flags, '-e', script], root: @root,
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

  describe 'the claim of a watcher the launcher stopped' do
    let(:lib) { File.expand_path('../../lib', __dir__) }

    # A managed daemon that claims the index exactly as `woods:watch` does,
    # then reports readiness. `on_term` and `wait` stand in for its shutdown path.
    def launch_claimed(on_term, wait = 'sleep 30')
      launch(<<~RUBY, flags: ['-rbundler/setup'])
        $LOAD_PATH.unshift(#{lib.inspect})
        require 'woods/watch/daemon'
        #{handshake}
        index = File.join(Dir.pwd, 'index')
        daemon = Woods::Watch::Daemon.new(root: Dir.pwd, output_dir: index, conservative_claims: true)
        abort 'claim unavailable' unless daemon.send(:claim_startup?)
        #{on_term}
        child.call(:startup, state: 'ready', generation: 1, reason: 'reconciled')
        #{wait}
      RUBY
      eventually { @supervisor.state == 'ready' }
      File.join(@root, 'index', 'watch_claim.json')
    end

    def stop_launcher
      @supervisor.stop
      expect(@thread.join(10).value).to eq(0)
    end

    it 'retires the claim of a watcher it had to kill after its shutdown timeout' do
      # Busy past the shutdown timeout, as a watcher in the middle of an extraction is.
      claim = launch_claimed("Signal.trap('TERM', 'IGNORE')")
      record = JSON.parse(File.read(claim))

      stop_launcher

      expect(File.exist?(claim)).to be(false)
      expect(@log.string).to include("retired the claim of stopped watcher pid #{record.fetch('pid')}")
      expect(@log.string).not_to include(record.fetch('token'))
      expect(File.exist?("#{claim}.lease")).to be(true)
      expect(File.exist?("#{claim}.lock")).to be(true)
    end

    it 'retires the extraction lock of a watcher it killed in the middle of an extraction, before its claim' do
      claim = launch_claimed(<<~RUBY)
        Signal.trap('TERM', 'IGNORE')
        abort 'extraction lock unavailable' unless Woods::Coordination::PipelineLock.for_index(index).acquire
      RUBY
      lock = File.join(File.dirname(claim), 'extraction.lock')
      pid = JSON.parse(File.read(lock)).fetch('pid')

      stop_launcher

      expect(File.exist?(lock)).to be(false)
      expect(File.exist?(claim)).to be(false)
      expect(File.exist?(File.join(File.dirname(claim), '.extraction.lock.guard'))).to be(true)
      retired_lock = @log.string.index("retired the extraction lock of stopped watcher pid #{pid} at ")
      retired_claim = @log.string.index("retired the claim of stopped watcher pid #{pid} at ")
      expect(retired_lock).to be < retired_claim
    end

    it 'still retires the claim when the extraction lock stays because its guard is busy' do
      claim = launch_claimed(<<~RUBY)
        Signal.trap('TERM', 'IGNORE')
        abort 'extraction lock unavailable' unless Woods::Coordination::PipelineLock.for_index(index).acquire
      RUBY
      lock = File.join(File.dirname(claim), 'extraction.lock')
      bytes = File.binread(lock)

      File.open(File.join(File.dirname(claim), '.extraction.lock.guard'), File::RDWR) do |guard|
        guard.flock(File::LOCK_EX)
        stop_launcher
      end

      expect(File.binread(lock)).to eq(bytes)
      expect(@log.string).to match(/left the extraction lock of stopped watcher pid \d+ at .* in place: another/)
      expect(File.exist?(claim)).to be(false)
      expect(@log.string).not_to include(JSON.parse(bytes).fetch('token'))
    end

    it 'leaves the claim when a process that escaped the watcher group still holds its lease' do
      # A forked copy in its own session keeps the inherited lease descriptor past the group KILL.
      claim = launch_claimed(<<~RUBY)
        Signal.trap('TERM', 'IGNORE')
        File.write('holder.pid', fork { Process.setsid; sleep 30 }.to_s)
      RUBY
      bytes = File.binread(claim)

      stop_launcher

      expect(File.binread(claim)).to eq(bytes)
      expect(@log.string).to match(/left the claim of stopped watcher pid \d+ at .* in place: owner lease is held/)
      expect(@log.string).not_to include(JSON.parse(bytes).fetch('token'))
    ensure
      holder = File.read(File.join(@root, 'holder.pid')).to_i if File.exist?(File.join(@root, 'holder.pid'))
      Process.kill('KILL', holder) if holder
    end

    it 'has nothing to do when the watcher released its own claim on a graceful stop' do
      claim = launch_claimed("Signal.trap('TERM') { $stop = true }",
                             'sleep 0.02 until $stop; daemon.send(:release_claim); exit 0')

      stop_launcher

      expect(File.exist?(claim)).to be(false)
      expect(@log.string).not_to include('claim')
    end
  end

  describe 'whether a stopped watcher group is gone' do
    subject(:supervisor) { described_class.new(command: [Gem.ruby], root: @root, logger: StringIO.new) }

    it 'counts a group whose only member is an unreaped zombie as gone, since it cannot write' do
      pid = fork do
        Process.setpgrp
        exit!(0)
      end
      sleep 0.02 until File.read("/proc/#{pid}/stat").split(') ').last.start_with?('Z')

      expect(supervisor.send(:watcher_group_gone?, pid)).to be(true)
    ensure
      Process.wait(pid)
    end

    it 'counts a group with a live member as present' do
      pid = fork do
        Process.setpgrp
        sleep 30
      end
      sleep 0.02 until File.read("/proc/#{pid}/stat").split(') ').last.split[2].to_i == pid

      expect(supervisor.send(:watcher_group_gone?, pid)).to be(false)
    ensure
      Process.kill('KILL', pid)
      Process.wait(pid)
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
