# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'timeout'
require 'woods/watch/managed_process'

RSpec.describe Woods::Watch::ManagedProcess do
  around do |example|
    Dir.mktmpdir('woods process space ') do |root|
      @root = root
      example.run
    end
  end

  after { @process&.stop }

  def start(code, **options)
    @process = described_class.new(command: [Gem.ruby, '-e', code], root: @root,
                                   env: ENV.to_h, shutdown_timeout: 0.2, **options).start
  end

  def eventually
    Timeout.timeout(5) { sleep 0.02 until yield }
  end

  it 'runs an argument vector in its root with no application stdin' do
    start('File.write("result", [Dir.pwd, STDIN.read].join("|"))')
    eventually { !@process.alive? }
    expect(File.read(File.join(@root, 'result'))).to eq("#{@root}|")
    expect(@process.exit_status).to eq(0)
  end

  it 'reaps a child that ignores TERM after bounded shutdown' do
    start('trap("TERM") {}; File.write("pid", Process.pid); sleep 30')
    eventually { File.exist?(File.join(@root, 'pid')) }
    pid = File.read(File.join(@root, 'pid')).to_i
    @process.stop
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  end

  it 'reports guardian hello and application exit separately from application output' do
    start('exit 75', events: true)
    records = []
    eventually do
      records.concat(@process.read_events)
      records.any? { |record| JSON.parse(record)['event'] == 'exit' }
    end
    parsed = records.map { |record| JSON.parse(record) }
    expect(parsed.map { |record| record['event'] }).to eq(%w[hello spawned exit])
    expect(parsed.last['code']).to eq(75)
  end

  it 'stops an application still booting when its owner disappears' do
    owner = fork do
      start('trap("TERM") {}; File.write("pid", Process.pid); sleep 30')
      sleep 30
    end
    eventually { File.exist?(File.join(@root, 'pid')) }
    pid = File.read(File.join(@root, 'pid')).to_i
    Process.kill('KILL', owner)
    Process.wait(owner)
    eventually do
      Process.kill(0, pid)
      false
    rescue Errno::ESRCH
      true
    end
  ensure
    Process.kill('KILL', owner) rescue nil # rubocop:disable Style/RescueModifier
    Process.wait(owner) rescue nil # rubocop:disable Style/RescueModifier
  end

  it 'bounds cleanup even when its guardian is stopped by a signal' do
    start('trap("TERM") {}; File.write("pid", Process.pid); sleep 30')
    eventually { File.exist?(File.join(@root, 'pid')) }
    @process.read_events
    Process.kill('STOP', @process.pid)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @process.stop
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    expect(@process).not_to be_alive
  end

  it 'stops its registered child even when the guardian is killed before cleanup' do
    start('trap("TERM") {}; File.write("pid", Process.pid); sleep 30')
    eventually { File.exist?(File.join(@root, 'pid')) }
    pid = File.read(File.join(@root, 'pid')).to_i
    Process.kill('KILL', @process.pid)
    eventually { !@process.alive? }
    @process.stop
    eventually { !running_process?(pid) }
    expect { @process.stop }.not_to raise_error
  end

  it 'does not execute the application if guardian dies before child registration is acknowledged' do
    process = described_class.new(command: [Gem.ruby, '-e', 'File.write("executed", "yes"); sleep 30'],
                                  root: @root, env: ENV.to_h, shutdown_timeout: 0.2)
    allow(process).to receive(:await_registration) do
      sleep 0.1
      Process.kill('KILL', process.pid)
      raise ArgumentError, 'interrupted registration'
    end
    @process = process
    expect { process.start }.to raise_error(ArgumentError, /interrupted/)
    sleep 0.2
    expect(File.exist?(File.join(@root, 'executed'))).to be false
  end

  it 'serializes diagnostic reads and cleanup across concurrent owners' do
    start('sleep 30')
    reader = @process.instance_variable_get(:@reader)
    entered = Queue.new
    release = Queue.new
    allow(reader).to receive(:read_nonblock).and_wrap_original do |original, *args, **options|
      entered << true
      release.pop
      original.call(*args, **options)
    end
    reading = Thread.new { @process.read_events }
    entered.pop
    closing = Thread.new { @process.close }
    release << true
    expect do
      reading.value
      closing.value
    end.not_to raise_error
  ensure
    release << true if release
  end

  it 'rejects a truncated protocol frame at EOF' do
    @process = described_class.new(command: ['true'], root: @root, env: {})
    reader, writer = IO.pipe
    @process.instance_variable_set(:@reader, reader)
    @process.instance_variable_set(:@stream, Woods::Watch::EventStream.new(reader: reader, guardian: 10,
                                                                           launcher: 'l', attempt: 'a'))
    writer.write('{"version":')
    writer.close

    expect { @process.read_events }.to raise_error(ArgumentError, /truncated/)
  end

  def running_process?(pid)
    stat = "/proc/#{pid}/stat"
    return false if File.file?(stat) && File.read(stat).split[2] == 'Z'

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::ENOENT
    false
  end
end
