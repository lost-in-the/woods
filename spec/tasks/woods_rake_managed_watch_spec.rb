# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'woods:watch managed child protocol' do
  let(:repo) { File.expand_path('../..', __dir__) }

  def rakefile(dir)
    <<~RUBY
      $LOAD_PATH.unshift(#{File.join(repo, 'lib').inspect})
      require 'rake'
      require 'woods'
      require 'woods/watch/daemon'
      require 'logger'
      require 'active_support/string_inquirer'
      module Rails
        def self.application = self
        def self.initialized? = false
        def self.root = Pathname.new(#{dir.inspect})
        def self.logger = Logger.new($stderr)
        def self.env = ActiveSupport::StringInquirer.new(ENV.fetch('TEST_RAILS_ENV', 'development'))
      end
      Woods.configuration.output_dir = File.join(#{dir.inspect}, 'custom index')
      class Woods::Watch::Daemon
        def run
          puts "managed=\#{!@lifecycle.nil?}; conservative=\#{@conservative_claims}"
          puts "idle=\#{@idle_timeout.inspect}"
          @lifecycle&.call(:backend_ready)
          @lifecycle&.call(:startup, state: 'ready', generation: 4, reason: 'reconciled')
          ENV.fetch('TEST_WATCH_REASON', 'stopped').to_sym
        end
      end
      task :environment do
        raise 'application boot failed' if ENV['TEST_BOOT_FAILURE'] == '1'
        puts 'environment loaded'
      end
      load #{File.join(repo, 'lib/tasks/woods.rake').inspect}
    RUBY
  end

  def run_watch(managed: true, **overrides)
    Dir.mktmpdir('woods-managed-task') do |dir|
      task_path = File.join(dir, 'Rakefile')
      File.write(task_path, rakefile(dir))
      File.open(File.join(dir, 'events'), 'w+') do |events|
        env = { 'WOODS_OUTPUT' => nil, 'WOODS_WATCH_IDLE_TIMEOUT' => nil,
                'WOODS_WATCH_EVENT_FD' => nil, 'WOODS_WATCH_LAUNCHER_TOKEN' => nil,
                'WOODS_WATCH_ATTEMPT_TOKEN' => nil }
        if managed
          env.merge!('WOODS_WATCH_EVENT_FD' => events.fileno.to_s,
                     'WOODS_WATCH_LAUNCHER_TOKEN' => 'task-launcher', 'WOODS_WATCH_ATTEMPT_TOKEN' => 'task-attempt')
        end
        out, err, status = Open3.capture3(env.merge(overrides.transform_keys(&:to_s)), RbConfig.ruby,
                                          File.join(repo, 'bin/rake'), '--rakefile', task_path, 'woods:watch',
                                          chdir: dir, events.fileno => events)
        events.rewind
        [out, err, status, events.each_line.map { |line| JSON.parse(line) }]
      end
    end
  end

  it 'reports the loaded task before boot, the actual custom index, and the terminal reason' do
    out, err, status, events = run_watch

    expect(status).to be_success, err
    expect(out).to include('managed=true; conservative=true')
    expect(events.map { |event| event['event'] }).to eq(%w[task_loaded identity backend_ready startup terminal])
    expect(events.first['woods_version']).to eq(Woods::VERSION)
    expect(events[1]['index']).to eq(File.join(events[1]['root'], 'custom index'))
    expect(events.last['reason']).to eq('stopped')
  end

  it 'keeps the raw task exit-75 contract while reporting the planned reason' do
    _out, err, status, events = run_watch(TEST_WATCH_REASON: 'restart_required')

    expect(status.exitstatus).to eq(75), err
    expect(events.last).to include('event' => 'terminal', 'reason' => 'restart_required')
  end

  it 'reports already-running distinctly despite its successful task exit' do
    _out, err, status, events = run_watch(TEST_WATCH_REASON: 'already_running')

    expect(status).to be_success, err
    expect(events.last).to include('event' => 'terminal', 'reason' => 'already_running')
  end

  it 'does not guess an index identity after failed Rails boot' do
    _out, _err, status, events = run_watch(TEST_BOOT_FAILURE: '1')

    expect(status).not_to be_success
    expect(events.map { |event| event['event'] }).to eq(['task_loaded'])
  end

  it 'rejects managed idle TTL before Rails boot even when it is zero' do
    out, err, status, events = run_watch(WOODS_WATCH_IDLE_TIMEOUT: '0')

    expect(status).not_to be_success
    expect(err).to include('WOODS_WATCH_IDLE_TIMEOUT must be unset')
    expect(out).not_to include('environment loaded')
    expect(events).to be_empty
  end

  it 'leaves raw tasks unmanaged and preserves their idle option' do
    out, err, status, events = run_watch(managed: false, WOODS_WATCH_IDLE_TIMEOUT: '1')

    expect(status).to be_success, err
    expect(out).to include('managed=false; conservative=false')
    expect(out).to include('idle=1.0')
    expect(events).to be_empty
  end

  ['', " \t "].each do |blank|
    [true, false].each do |managed|
      it "treats #{blank.inspect} idle timeout as unset with managed=#{managed}" do
        out, err, status, events = run_watch(managed: managed, WOODS_WATCH_IDLE_TIMEOUT: blank)

        expect(status).to be_success, err
        expect(out).to include('idle=nil')
        expect(events.last['reason']).to eq('stopped') if managed
      end
    end
  end

  it 'reports invalid raw timeout configuration before running the daemon' do
    out, err, status, events = run_watch(managed: false, WOODS_WATCH_IDLE_TIMEOUT: 'invalid')

    expect(status).not_to be_success
    expect(err).to include('WOODS_WATCH_IDLE_TIMEOUT')
    expect(out).not_to include('managed=false')
    expect(events).to be_empty
  end

  it 'parks managed watching in a finalized non-development Rails environment' do
    out, err, status, events = run_watch(TEST_RAILS_ENV: 'production')

    expect(status).to be_success, err
    expect(out).not_to include('managed=true')
    expect(events.map { |event| event['event'] }).to eq(%w[task_loaded terminal])
    expect(events.last['reason']).to eq('unsupported_environment')
  end
end
