# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'bundler'

# Rails generator loading is intentionally isolated: loading a partial Rails
# constant in the default suite changes unrelated MCP runtime detection.
RSpec.describe 'Woods watcher Rails generator' do
  around do |example|
    Dir.mktmpdir('woods generator ') do |root|
      @root = root
      File.write(File.join(root, 'Gemfile'), '')
      File.write(File.join(root, 'Procfile.dev'), "web: bin/rails server\n")
      example.run
    end
  end

  def generate(*arguments, behavior: 'invoke')
    repo = File.expand_path('../..', __dir__)
    environment = Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => File.join(repo, 'Gemfile'),
                                              'BUNDLE_LOCKFILE' => File.join(repo, 'Gemfile.lock'))
    script = <<~SCRIPT
      require 'bundler/setup'
      require 'generators/woods/watch_generator'
      class Woods::Watch::Installation::Probe
        def call(**)
          true
        end
      end
      root, behavior = ARGV.shift(2)
      Woods::Generators::WatchGenerator.start(ARGV, destination_root: root, behavior: behavior.to_sym)
    SCRIPT
    Open3.capture3(environment, Gem.ruby, '-I', File.join(repo, 'lib'), '-e', script,
                   @root, behavior, *arguments, unsetenv_others: true)
  end

  it 'honors Rails generator pretend without creating receipts or runtime state' do
    stdout, stderr, status = generate('--mode', 'puma', '--pretend')
    expect(status.success?).to be(true), stderr
    expect(stdout).to include('write')
    expect(Dir.children(@root).sort).to eq(%w[Gemfile Procfile.dev])
  end

  it 'writes portable Puma configuration and supports the ordinary generator revoke path' do
    stdout, stderr, status = generate('--mode', 'puma')
    expect(status.success?).to be(true), stderr
    expect(stdout).to include('applied')
    config = File.join(@root, 'config/puma.rb')
    expect(File.read(config)).to include('plugin :woods if Gem.loaded_specs.key?("woods")')

    stdout, stderr, status = generate(behavior: 'revoke')
    expect(status.success?).to be(true), stderr
    expect(stdout).to include('applied')
    expect(File.exist?(config)).to be(false)
    expect(File.exist?(File.join(@root, '.woods-watch.json'))).to be(false)
  end

  it 'requires explicit startup selection and gives a usable error before changing anything' do
    _stdout, stderr, _status = generate('--mode', 'procfile')
    expect(stderr).to match(/Foreman.*Puma/m)
    expect(Dir.children(@root).sort).to eq(%w[Gemfile Procfile.dev])
  end

  it 'exposes recovery without needing mode selection or a bootable Gemfile' do
    File.unlink(File.join(@root, 'Gemfile'))
    stdout, stderr, status = generate('--operation', 'recover')
    expect(status.success?).to be(true), stderr
    expect(stdout).to include('nothing_to_recover')
  end
end
