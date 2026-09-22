# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/watch/installation'

RSpec.describe Woods::Watch::Installation::Probe do
  around do |example|
    Dir.mktmpdir('woods probe ') do |root|
      @root = root
      File.write(File.join(root, 'Gemfile'), '')
      example.run
    end
  end

  def executable(name, source)
    path = File.join(@root, name)
    File.write(path, "#!#{Gem.ruby}\n#{source}\n")
    File.chmod(0o755, path)
    path
  end

  def probe(**options)
    described_class.new(environment: {}, **options)
  end

  it 'only lists the watch task and probes the selected manager without starting services' do
    task = executable('rails',
                      "abort 'started watch' unless ARGV == ['-T', 'woods:watch']; puts 'rails woods:watch # watch'")
    manager = executable('foreman', "abort 'started services' unless ARGV == ['--version']; puts '0.90.0'")

    expect(probe.call(root: @root, child_command: [task, 'woods:watch'],
                      manager_command: [manager, 'start', '-f', 'Procfile.dev'])).to be(true)
  end

  it 'rejects a wrapper that cannot see the Rails watch task' do
    task = executable('rails', "puts 'rake compose:up # host wrapper'")

    expect { probe.call(root: @root, child_command: [task, 'woods:watch']) }
      .to raise_error(Woods::Watch::Installation::Conflict, /does not expose woods:watch/)
  end

  it 'uses the selected application environment for both task and manager probes without inherited activation' do
    captured = File.join(@root, 'environments.jsonl')
    source = "require 'json'; File.open(#{captured.inspect}, 'a') { |f| f.puts JSON.generate(ENV.to_h) }; " \
             "puts 'rails woods:watch'"
    task = executable('rails', source)
    manager = executable('foreman', source)
    settings = { 'RAILS_ENV' => 'development', 'APP_SETTING' => 'retained', 'BUNDLE_WITHOUT' => 'production',
                 'BUNDLE_APP_CONFIG' => '/selected/configuration', 'BUNDLE_PATH' => '/selected/gems',
                 'BUNDLE_BIN_PATH' => '/stale/bundler', 'RUBYOPT' => '-r/missing/setup',
                 'BUNDLER_ORIG_RUBYOPT' => Woods::Watch::ChildEnvironment::NIL_VALUE }

    described_class.new(environment: settings).call(root: @root, child_command: [task, 'woods:watch'],
                                                    manager_command: [manager, 'start', '-f', 'Procfile.dev'])
    environments = File.readlines(captured).map { |line| JSON.parse(line) }
    expect(environments.size).to eq(2)
    environments.each do |environment|
      expect(environment).to include(settings.slice('RAILS_ENV', 'APP_SETTING', 'BUNDLE_WITHOUT',
                                                    'BUNDLE_APP_CONFIG', 'BUNDLE_PATH'))
      expect(environment.keys.grep(/\ABUNDLER_ORIG_|\ABUNDLE_BIN_PATH\z|\ARUBYOPT\z/)).to be_empty
    end
  end

  [
    { selected: '/activated.lock', original: '/requested.lock', expected: '/requested.lock' },
    { selected: '/activated.lock', original: Woods::Watch::ChildEnvironment::NIL_VALUE, expected: nil },
    { selected: '/explicit.lock', expected: '/explicit.lock' }
  ].each do |selection|
    it "uses the selected lockfile without leaking parent activation: #{selection.inspect}" do
      captured = File.join(@root, 'lockfile')
      task = executable('rails',
                        "File.write(#{captured.inspect}, ENV.fetch('BUNDLE_LOCKFILE')); puts 'rails woods:watch'")
      environment = { 'BUNDLE_GEMFILE' => 'Gemfile', 'BUNDLE_LOCKFILE' => selection.fetch(:selected) }
      environment['BUNDLER_ORIG_BUNDLE_LOCKFILE'] = selection[:original] if selection.key?(:original)

      described_class.new(environment: environment).call(root: @root, child_command: [task, 'woods:watch'])

      expect(File.read(captured)).to eq(selection[:expected] || File.join(@root, 'Gemfile.lock'))
    end
  end

  it 'rejects an unavailable manager command' do
    task = executable('rails', "puts 'rails woods:watch # watch'")

    expect do
      probe.call(root: @root, child_command: [task, 'woods:watch'],
                 manager_command: [File.join(@root, 'missing'), 'start', '-f', 'Procfile.dev'])
    end.to raise_error(Woods::Watch::Installation::Conflict, /could not run/)
  end

  it 'bounds a hanging application probe and reaps its child' do
    pid_file = File.join(@root, 'pid')
    task = executable('rails', "File.write(#{pid_file.inspect}, Process.pid); sleep 60")

    expect { probe(timeout: 0.3).call(root: @root, child_command: [task, 'woods:watch']) }
      .to raise_error(Woods::Watch::Installation::Conflict, /exceeded/)
    pid = Integer(File.read(pid_file))
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  end

  it 'reports failed task discovery without mutating installation files' do
    task = executable('rails', "warn 'missing task'; exit 1")

    expect { probe.call(root: @root, child_command: [task, 'woods:watch']) }
      .to raise_error(Woods::Watch::Installation::Conflict, /missing task/)
    expect(File.exist?(File.join(@root, '.woods-watch.json'))).to be(false)
  end

  it 'rejects unsupported Puma major versions through its isolated installed-version check' do
    File.write(File.join(@root, 'puma.rb'), <<~RUBY)
      Gem.loaded_specs['puma'] = Struct.new(:version).new(Gem::Version.new('5.6.0'))
    RUBY
    stdout, stderr, status = Open3.capture3(Bundler.unbundled_env, Gem.ruby, '-I', @root,
                                            '-e', described_class::PUMA_CHECK, unsetenv_others: true)

    expect(status.success?).to be(false), stdout
    expect(stderr).to include('Supported Puma 6/7/8')
  end
end
