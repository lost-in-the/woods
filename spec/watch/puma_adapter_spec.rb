# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'
require 'woods/watch/puma_adapter'

RSpec.describe Woods::Watch::PumaAdapter do
  let(:events) { Object.new }
  let(:hooks) { {} }
  let(:messages) { [] }
  let(:logger) { double('logger', log: nil) }
  let(:environment) { 'development' }
  let(:launcher) do
    double('Puma launcher', events: events, options: { directory: @root, environment: environment }, log_writer: logger)
  end
  let(:child) { instance_double(Woods::Watch::PumaChild, start: 123, stop: nil) }

  before do
    @root = Dir.mktmpdir('woods puma ')
    FileUtils.mkdir_p(File.join(@root, 'bin'))
    File.write(File.join(@root, 'bin/woods-watch'), '# application wrapper')
    allow(Dir).to receive(:pwd).and_return(@root)
    registered_hooks = hooks
    %i[after_booted before_restart after_stopped].each do |name|
      events.define_singleton_method(name) { |&block| registered_hooks[name] = block }
    end
    allow(logger).to receive(:log) { |message| messages << message }
    allow(Woods::Watch::PumaChild).to receive(:new).and_return(child)
  end

  after { FileUtils.remove_entry(@root) }

  def adapter(version: '8.0.2', platform: 'x86_64-linux')
    described_class.new(launcher, puma_version: version, platform: platform)
  end

  it 'waits for Puma boot and starts once even when a phased restart fires booted again' do
    integration = adapter
    integration.install
    expect(child).not_to have_received(:start)
    hooks.fetch(:after_booted).call
    hooks.fetch(:after_booted).call
    expect(child).to have_received(:start).once
    expect(Woods::Watch::PumaChild).to have_received(:new).with(root: @root, environment: 'development', logger: logger)
    expect(messages.join).to include('index readiness is reported separately')
  end

  it 'registers lifecycle hooks only once' do
    integration = adapter
    integration.install
    original_hooks = hooks.dup
    integration.install
    expect(hooks).to eq(original_hooks)
  end

  it 'does not start from a forked worker callback' do
    integration = adapter
    integration.install
    allow(Process).to receive(:pid).and_return(123_456)
    hooks.fetch(:after_booted).call
    expect(child).not_to have_received(:start)
  end

  %w[production test staging].each do |name|
    context "with Puma's resolved #{name} environment" do
      let(:environment) { name }

      it 'does not start a watcher' do
        adapter.install
        hooks.fetch(:after_booted).call
        expect(child).not_to have_received(:start)
      end
    end
  end

  context 'with no resolved environment' do
    let(:environment) { nil }

    it 'fails closed instead of assuming development' do
      adapter.install
      hooks.fetch(:after_booted).call
      expect(child).not_to have_received(:start)
    end
  end

  %i[before_restart after_stopped].each do |event|
    it "reaps the owned launcher on #{event}" do
      adapter.install
      hooks.fetch(:after_booted).call
      hooks.fetch(event).call
      expect(child).to have_received(:stop)
    end
  end

  it 'supports the legacy Puma 6 event names' do
    %i[after_booted before_restart after_stopped].each { |name| events.singleton_class.remove_method(name) }
    registered_hooks = hooks
    %i[on_booted on_restart on_stopped].each do |name|
      events.define_singleton_method(name) { |&block| registered_hooks[name] = block }
    end
    adapter(version: '6.6.1').install
    hooks.fetch(:on_booted).call
    hooks.fetch(:on_restart).call
    expect(child).to have_received(:start).once
    expect(child).to have_received(:stop).once
  end

  it 'leaves Puma running with a useful diagnostic when the wrapper is missing' do
    File.unlink(File.join(@root, 'bin/woods-watch'))
    adapter.install
    expect { hooks.fetch(:after_booted).call }.not_to raise_error
    expect(child).not_to have_received(:start)
    expect(messages.join).to include('generate woods:watch --mode=puma', 'inactive')
  end

  it 'does not turn a failed spawn into a Puma shutdown or a second retry loop' do
    allow(child).to receive(:start).and_raise(Errno::EACCES)
    adapter.install
    2.times { hooks.fetch(:after_booted).call }
    expect(child).to have_received(:start).once
    expect(messages.join).to include('Errno::EACCES', 'process manager')
  end

  [['5.6.9', 'x86_64-linux'], ['9.0.0', 'x86_64-linux'], ['8.0.2', 'x64-mingw-ucrt'], ['8.0.2', 'x86_64-cygwin'],
   ['8.0.2', 'java']].each do |version, platform|
    it "provides a standalone fallback for unsupported Puma #{version} on #{platform}" do
      adapter(version: version, platform: platform).install
      expect(hooks).to be_empty
      expect(messages.join).to include('unsupported', 'bin/woods-watch')
    end
  end
end

RSpec.describe Woods::Watch::PumaChild do
  let(:messages) { [] }
  let(:logger) { double('logger') }

  before do
    @root = Dir.mktmpdir('woods puma child ')
    FileUtils.mkdir_p(File.join(@root, 'bin'))
    allow(logger).to receive(:log) { |message| messages << message }
  end

  after do
    @child&.stop
    FileUtils.remove_entry(@root)
  end

  def write_wrapper(body)
    File.write(File.join(@root, 'bin/woods-watch'), body)
  end

  def start_child
    @child = described_class.new(root: @root, environment: 'development', logger: logger, stop_grace: 0.3)
    @child.start
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until yield
      raise 'subprocess did not reach the expected state' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  it 'normalizes the child environment, preserves app cwd, and reserves no debugger stdin' do
    write_wrapper(<<~RUBY)
      require 'json'
      File.write('started.json.tmp', JSON.generate({
        env: ENV.values_at('APP_ENV', 'RACK_ENV', 'RAILS_ENV'),
        cwd: Dir.pwd, stdin: $stdin.read
      }))
      File.rename('started.json.tmp', 'started.json')
      sleep
    RUBY
    pid = start_child
    wait_until { File.exist?(File.join(@root, 'started.json')) }
    data = JSON.parse(File.read(File.join(@root, 'started.json')))
    expect(data).to include('env' => %w[development development development], 'cwd' => @root, 'stdin' => '')
    @child.stop
    expect { Process.waitpid(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    expect(messages).to be_empty
  end

  it 'reports a launcher failure without retrying it' do
    write_wrapper("File.open('attempts', 'a') { |file| file.puts(Process.pid) }; exit 75")
    start_child
    wait_until { messages.any? }
    expect(messages.join).to include('stopped unexpectedly', 'automatic maintenance is inactive')
    expect(File.readlines(File.join(@root, 'attempts')).size).to eq(1)
  end

  it 'bounds shutdown when the launcher ignores TERM and reaps it' do
    write_wrapper("Signal.trap('TERM') {}; File.write('started', Process.pid.to_s); sleep")
    pid = start_child
    wait_until { File.exist?(File.join(@root, 'started')) }
    @child.stop
    expect { Process.waitpid(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    expect(messages).to be_empty
  end

  it 'cleans up its launcher before reporting unexpected guardian death' do
    write_wrapper(<<~RUBY)
      File.write('launcher.pid.tmp', Process.pid)
      File.rename('launcher.pid.tmp', 'launcher.pid')
      sleep
    RUBY
    guardian = start_child
    wait_until { File.exist?(File.join(@root, 'launcher.pid')) }
    launcher_pid = Integer(File.read(File.join(@root, 'launcher.pid')))
    Process.kill('KILL', guardian)
    wait_until { messages.any? }
    wait_until do
      stat = "/proc/#{launcher_pid}/stat"
      next true if File.file?(stat) && File.read(stat).split[2] == 'Z'

      Process.kill(0, launcher_pid)
      false
    rescue Errno::ESRCH, Errno::ENOENT
      true
    end
  ensure
    begin
      Process.kill('KILL', -launcher_pid) if launcher_pid
    rescue Errno::ESRCH
      nil
    end
  end
end
