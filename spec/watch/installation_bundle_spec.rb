# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'woods/watch/installation'

RSpec.describe 'Watcher installation with an application-owned bundle' do
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
    FileUtils.mkdir_p(File.join(source, 'exe'))
    File.write(File.join(source, 'exe/rails'), <<~RUBY)
      #!/usr/bin/env ruby
      abort 'Unexpected task invocation' unless ARGV == ['-T', 'woods:watch']
      abort 'Preflight must freeze resolution' unless ENV['BUNDLE_FROZEN'] == 'true'
      puts 'rails woods:watch # fixture task discovered through the selected bundle'
    RUBY
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
        spec.name = 'woods-watcher-preflight-fixture'
        spec.version = '0.0.1'
        spec.summary = 'Local watcher preflight fixture'
        spec.authors = ['Woods tests']
        spec.files = ['exe/rails']
        spec.bindir = 'exe'
        spec.executables = ['rails']
      end
    RUBY
  end

  def write_application_bundle
    File.write(File.join(@root, 'Gemfile'), <<~GEMFILE)
      source 'https://rubygems.org'
      gem 'woods-watcher-preflight-fixture', '0.0.1'
      group :unused_probe_group do
        gem 'woods-uninstalled-probe-fixture', '0.0.1'
      end
    GEMFILE
    File.write(File.join(@root, 'Gemfile.lock'), <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
          woods-uninstalled-probe-fixture (0.0.1)
          woods-watcher-preflight-fixture (0.0.1)

      PLATFORMS
        ruby

      DEPENDENCIES
        woods-uninstalled-probe-fixture (= 0.0.1)
        woods-watcher-preflight-fixture (= 0.0.1)

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
    probe = Woods::Watch::Installation::Probe.new(environment: selected_environment)
    command = [Gem.ruby, Gem.bin_path('bundler', 'bundle'), 'exec', 'rails', 'woods:watch']

    expect(probe.call(root: @root, child_command: command)).to be(true)
    expect(application_files).to eq(files)
    expect(selected_environment['BUNDLE_FROZEN']).to eq('false')
  end

  def application_files
    Dir.glob('**/*', File::FNM_DOTMATCH, base: @root).filter_map do |relative|
      path = File.join(@root, relative)
      [relative, File.binread(path)] if File.file?(path)
    end.to_h
  end

  it 'discovers a gem executable installed only at the environment-selected BUNDLE_PATH' do
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
