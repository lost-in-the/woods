# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'socket'
require 'json'
require 'timeout'
require 'puma'

# Exercise Puma's actual master hooks, forks and exec restarts. The small wrapper
# records process ownership; extraction and managed retry semantics have their
# own booted Rails tests using the same shared launcher.
RSpec.describe 'Puma-managed watcher lifecycle' do
  let(:repo) { File.expand_path('../..', __dir__) }
  let(:puma_executable) { Gem.bin_path('puma', 'puma') }

  around do |example|
    Dir.mktmpdir('woods-puma-') do |root|
      @root = root
      @server = nil
      FileUtils.mkdir_p(File.join(root, 'bin'))
      File.write(File.join(root, 'bin/woods-watch'), wrapper)
      example.run
    ensure
      warn File.read(log_path) if example.exception && File.file?(log_path)
      stop_server
    end
  end

  def wrapper
    <<~CODE
      require 'json'
      File.open('launches.jsonl', 'a') do |file|
        file.puts JSON.generate(pid: Process.pid, cwd: Dir.pwd, env: ENV.values_at('APP_ENV', 'RACK_ENV', 'RAILS_ENV'))
      end
      Signal.trap('TERM') { exit }
      sleep
    CODE
  end

  def launch(configuration: '', env: {}, args: [], guarded: false)
    config = <<~RUBY_CONFIG
      directory #{@root.inspect}
      bind #{"unix://#{@root}/puma.sock".inspect}
      threads 0, 2
      workers 0
      #{configuration}
      app ->(_env) { [200, { 'content-type' => 'text/plain' }, [Process.pid.to_s]] }
      #{guarded ? 'plugin :woods if Gem.loaded_specs.key?("woods")' : 'plugin :woods'}
    RUBY_CONFIG
    File.write(File.join(@root, 'puma.rb'), config)
    # Reuse the active test bundle so CI can select Puma 6, 7 or 8 without
    # accidentally activating the newest Puma installed elsewhere on the host.
    gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', File.join(repo, 'Gemfile')))
    process_env = Bundler.unbundled_env.merge('APP_ENV' => nil, 'RACK_ENV' => nil, 'RAILS_ENV' => nil,
                                              'BUNDLE_GEMFILE' => gemfile).merge(env)
    process_env['BUNDLE_LOCKFILE'] = "#{process_env.fetch('BUNDLE_GEMFILE')}.lock"
    @server = Process.spawn(process_env, RbConfig.ruby, '-rbundler/setup', '-I', File.join(repo, 'lib'),
                            puma_executable, '-C', File.join(@root, 'puma.rb'), *args,
                            chdir: @root, in: File::NULL, out: log_path, err: %i[child out], pgroup: true,
                            unsetenv_others: true)
    wait_until { request.include?('200 OK') }
  end

  def log_path
    File.join(@root, 'puma.log')
  end

  def request
    return '' unless File.socket?(File.join(@root, 'puma.sock'))

    Timeout.timeout(2) do
      UNIXSocket.open(File.join(@root, 'puma.sock')) do |socket|
        socket.write("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
        socket.read
      end
    end
  rescue Errno::ECONNREFUSED, Errno::ENOENT, Errno::ECONNRESET, EOFError, Timeout::Error
    ''
  end

  def wait_until(timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "Puma fixture timed out:\n#{File.read(log_path) if File.exist?(log_path)}"
      end

      sleep 0.05
    end
  end

  def launches
    path = File.join(@root, 'launches.jsonl')
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def running?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def stop_server(signal = 'TERM')
    return unless @server

    Process.kill(signal, @server)
    Timeout.timeout(15) { Process.waitpid(@server) }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    if @server
      begin
        Process.kill('KILL', -@server)
      rescue Errno::ESRCH
        nil
      end
    end
    @server = nil
  end

  it 'runs one development child with normalized environment and reaps it on server shutdown' do
    launch(configuration: "environment 'development'", env: { 'APP_ENV' => 'production', 'RAILS_ENV' => 'test' })
    wait_until { launches.size == 1 }
    launch_info = launches.first
    expect(launch_info).to include('cwd' => @root, 'env' => %w[development development development])
    expect(request).to include(@server.to_s)
    stop_server
    expect(running?(launch_info.fetch('pid'))).to be(false)
  end

  it 'uses the resolved application directory when Puma was configured with a relative directory' do
    application = File.join(@root, 'application')
    FileUtils.mkdir_p(File.join(application, 'bin'))
    source = wrapper.sub("'launches.jsonl'", File.join(@root, 'launches.jsonl').inspect)
    File.write(File.join(application, 'bin/woods-watch'), source)
    launch(configuration: "directory 'application'")
    wait_until(timeout: 2) { launches.size == 1 }
    expect(launches.first.fetch('cwd')).to eq(application)
  end

  %w[APP_ENV RACK_ENV RAILS_ENV].each do |key|
    it "does not start in production selected through #{key}" do
      launch(env: { key => 'production' })
      expect(launches).to be_empty
      expect(File.read(log_path)).to include('Environment: production')
    end
  end

  it 'does not start when CLI -e selects production despite a development shell' do
    launch(env: { 'APP_ENV' => 'development' }, args: ['-e', 'production'])
    expect(launches).to be_empty
    expect(File.read(log_path)).to include('Environment: production')
  end

  it 'does not start when the Puma configuration selects production' do
    launch(configuration: "environment 'production'")
    expect(launches).to be_empty
  end

  it 'boots the committed guarded plugin configuration when the bundle excludes Woods' do
    gemfile = File.join(@root, 'Gemfile.production')
    File.write(gemfile, "source 'https://rubygems.org'\ngem 'puma', '#{Puma::Const::PUMA_VERSION}'\n")
    launch(configuration: <<~CONFIG, env: { 'BUNDLE_GEMFILE' => gemfile }, guarded: true)
      environment 'production'
      raise 'Woods unexpectedly activated' if Gem.loaded_specs.key?('woods')
    CONFIG
    expect(request).to include('200 OK')
    expect(launches).to be_empty
  end

  it 'starts only once for a preloaded server with two workers' do
    launch(configuration: "workers 2\npreload_app! true")
    wait_until { launches.size == 1 }
    expect(request).to include('200 OK')
    stop_server
    expect(launches.size).to eq(1)
    expect(running?(launches.first.fetch('pid'))).to be(false)
  end

  it 'keeps its launcher through a phased worker restart without duplicating it' do
    worker_hook = Puma::Const::PUMA_VERSION.split('.').first.to_i >= 8 ? 'before_worker_boot' : 'on_worker_boot'
    launch(configuration: <<~CONFIG)
      workers 2
      preload_app! false
      #{worker_hook} { File.open('workers', 'a') { |file| file.puts(Process.pid) } }
    CONFIG
    wait_until { launches.size == 1 && File.readlines(File.join(@root, 'workers')).size >= 2 }
    child_pid = launches.first.fetch('pid')
    Process.kill('USR1', @server)
    wait_until { File.readlines(File.join(@root, 'workers')).size >= 4 }
    expect(request).to include('200 OK')
    expect(launches.map { |entry| entry.fetch('pid') }).to eq([child_pid])
    stop_server
    expect(running?(child_pid)).to be(false)
  end

  it 'reaps the old launcher and starts one replacement after a hot restart' do
    launch
    wait_until { launches.size == 1 }
    first_pid = launches.first.fetch('pid')
    master_pid = @server
    Process.kill('USR2', @server)
    wait_until { launches.size == 2 && request.include?('200 OK') }
    expect(@server).to eq(master_pid)
    expect(running?(first_pid)).to be(false)
    stop_server
    expect(launches.size).to eq(2)
    expect(launches.none? { |entry| running?(entry.fetch('pid')) }).to be(true)
  end

  it 'stops its launcher when the master is killed without running shutdown hooks' do
    launch
    wait_until { launches.size == 1 }
    child_pid = launches.first.fetch('pid')
    stop_server('KILL')
    wait_until { !running?(child_pid) }
  end

  it 'detects master death even if a later fork retains its parent-liveness writer' do
    hook = Puma::Const::PUMA_VERSION.split('.').first.to_i >= 8 ? 'after_booted' : 'on_booted'
    launch(configuration: <<~CONFIG)
      #{hook} do
        Thread.new do
          sleep 0.02 until File.exist?('launches.jsonl')
          fork do
            File.write('retained-writer.pid', Process.pid.to_s)
            sleep
          end
        end
      end
    CONFIG
    wait_until { launches.size == 1 && File.exist?(File.join(@root, 'retained-writer.pid')) }
    child_pid = launches.first.fetch('pid')
    retaining_pid = File.read(File.join(@root, 'retained-writer.pid')).to_i
    Process.kill('KILL', @server)
    Process.waitpid(@server)
    # Leave the other fork alive: pipe EOF alone cannot detect this parent loss.
    wait_until { !running?(child_pid) }
    expect(running?(retaining_pid)).to be(true)
  end

  it 'keeps serving requests if the application wrapper fails' do
    File.write(File.join(@root, 'bin/woods-watch'), "exit 1\n")
    launch
    wait_until { File.read(log_path).include?('launcher stopped unexpectedly') }
    expect(request).to include('200 OK')
  end

  it 'finishes nested launcher cleanup before Puma exits when the managed task ignores TERM' do
    lib = File.join(repo, 'lib')
    task = File.join(@root, 'stubborn-task.rb')
    File.write(File.join(@root, 'bin/woods-watch'), <<~WRAPPER)
      require 'json'
      File.open('launches.jsonl', 'a') do |file|
        file.puts JSON.generate(pid: Process.pid, guardian: Process.ppid)
      end
      exec Gem.ruby, '-I', #{lib.inspect}, #{File.join(repo, 'exe/woods-watch').inspect},
           '--root', Dir.pwd, '--', Gem.ruby, '-I', #{lib.inspect}, #{task.inspect}
    WRAPPER
    File.write(task, <<~TASK)
      require 'json'
      require 'woods/watch/managed_child'
      require 'woods/version'
      Signal.trap('TERM') { File.write('task-term-received', 'ignored') }
      reporter = Woods::Watch::ManagedChild.from_env
      reporter.call(:task_loaded, woods_version: Woods::VERSION)
      reporter.call(:identity, root: Dir.pwd, index: File.join(Dir.pwd, 'index'))
      reporter.call(:backend_ready)
      reporter.call(:startup, state: 'ready', generation: 1, reason: 'reconciled')
      File.write('task-ready.json', JSON.generate(pid: Process.pid, guardian: Process.ppid))
      sleep
    TASK
    launch
    wait_until { File.exist?(File.join(@root, 'task-ready.json')) && File.read(log_path).include?('ready: reconciled') }
    owned_pids = launches.first.values_at('pid', 'guardian') +
                 JSON.parse(File.read(File.join(@root, 'task-ready.json'))).values_at('pid', 'guardian')
    expect(owned_pids.uniq.size).to eq(4)
    expect(owned_pids).to all(satisfy { |pid| running?(pid) })

    # Exercise the actual ten-second launcher grace and fifteen-second outer
    # Puma grace. All four owned processes must already be gone when stop returns.
    stop_server
    expect(File.read(File.join(@root, 'task-term-received'))).to eq('ignored')
    expect(owned_pids).to all(satisfy { |pid| !running?(pid) })
  end
end
