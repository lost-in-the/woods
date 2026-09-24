# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'woods/agent_configuration/preflight'
require 'woods/agent_configuration/launcher'

RSpec.describe 'Agent configuration preflight with an application-owned bundle' do
  around do |example|
    Dir.mktmpdir('woods bundle probe ') do |directory|
      @directory = directory
      @root = File.join(directory, 'application')
      @bundle = File.join(directory, 'private bundle')
      FileUtils.mkdir_p(@root)
      install_fixture
      write_application_bundle
      example.run
    end
  end

  def run_fixture_command(*command, **options)
    output, status = Open3.capture2e(Bundler.unbundled_env, *command, **options, unsetenv_others: true)
    raise output unless status.success?
  end

  def install_fixture
    source = File.join(@directory, 'fixture')
    FileUtils.mkdir_p(File.join(source, 'lib'))
    File.write(File.join(source, 'lib/woods-agent-preflight-fixture.rb'), "AGENT_PREFLIGHT_FIXTURE = true\n")
    write_fixture_spec(source)
    package = File.join(@directory, 'fixture.gem')
    run_fixture_command(Gem.ruby, '-S', 'gem', 'build', '--output', package, 'fixture.gemspec', chdir: source)
    gem_home = File.join(@bundle, 'ruby', RbConfig::CONFIG.fetch('ruby_version'))
    run_fixture_command(Gem.ruby, '-S', 'gem', 'install', '--local', '--ignore-dependencies', '--no-document',
                        '--install-dir', gem_home, package)
  end

  def write_fixture_spec(source)
    File.write(File.join(source, 'fixture.gemspec'), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = 'woods-agent-preflight-fixture'
        spec.version = '0.0.1'
        spec.summary = 'Local agent preflight fixture'
        spec.authors = ['Woods tests']
        spec.files = ['lib/woods-agent-preflight-fixture.rb']
      end
    RUBY
  end

  def write_application_bundle
    File.write(File.join(@root, 'Gemfile'), <<~GEMFILE)
      source 'https://rubygems.org'
      gem 'woods-agent-preflight-fixture', '0.0.1'
      group :unused_probe_group do
        gem 'woods-uninstalled-probe-fixture', '0.0.1'
      end
    GEMFILE
    File.write(File.join(@root, 'Gemfile.lock'), <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
          woods-uninstalled-probe-fixture (0.0.1)
          woods-agent-preflight-fixture (0.0.1)

      PLATFORMS
        ruby

      DEPENDENCIES
        woods-uninstalled-probe-fixture (= 0.0.1)
        woods-agent-preflight-fixture (= 0.0.1)

      BUNDLED WITH
         #{Bundler::VERSION}
    LOCK
  end

  def environment
    Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => File.join(@root, 'Gemfile'),
                                'BUNDLE_LOCKFILE' => File.join(@root, 'Gemfile.lock'),
                                'BUNDLE_PATH' => nil, 'BUNDLE_APP_CONFIG' => nil,
                                'BUNDLE_IGNORE_CONFIG' => nil, 'BUNDLE_FROZEN' => 'false',
                                'BUNDLE_WITHOUT' => 'unused_probe_group')
  end

  def verify_discovery(selected_environment)
    files = application_files
    selected_environment = selected_environment.merge('BUNDLE_GEMFILE' => File.join(@directory, 'wrong-caller-Gemfile'))
    original_environment = selected_environment.dup
    allow(ENV).to receive(:to_h).and_return(selected_environment)
    probe = Woods::AgentConfiguration::Preflight.new

    expect(probe.call(fixture_launcher)).to include('version' => 'fixture')
    expect(application_files).to eq(files)
    expect(selected_environment).to eq(original_environment)
  end

  def fixture_launcher
    launcher = Woods::AgentConfiguration::Launcher.new(root: @root)
    payload = JSON.generate(version: 'fixture', tools: Woods::AgentConfiguration::Preflight::REQUIRED_TOOLS)
    script = <<~RUBY
      require 'woods-agent-preflight-fixture'
      abort 'Private bundle was not loaded' unless AGENT_PREFLIGHT_FIXTURE
      abort 'Preflight must freeze resolution' unless ENV['BUNDLE_FROZEN'] == 'true'
      puts #{payload.inspect}
    RUBY
    allow(launcher).to(receive(:probe_command).and_wrap_original { |original, _script| original.call(script) })
    launcher
  end

  def application_files
    Dir.glob('**/*', File::FNM_DOTMATCH, base: @root).filter_map do |relative|
      path = File.join(@root, relative)
      [relative, File.binread(path)] if File.file?(path)
    end.to_h
  end

  it 'loads a gem installed only at the environment-selected BUNDLE_PATH' do
    verify_discovery(environment.merge('BUNDLE_PATH' => @bundle))
  end

  it 'discovers the bundle through BUNDLE_APP_CONFIG without writing application-local settings' do
    configuration = File.join(@directory, 'external configuration')
    FileUtils.mkdir_p(configuration)
    config = File.join(configuration, 'config')
    contents = "---\nBUNDLE_PATH: #{@bundle.inspect}\n"
    File.write(config, contents)

    verify_discovery(environment.merge('BUNDLE_APP_CONFIG' => configuration))
    expect(File.read(config)).to eq(contents)
  end
end
