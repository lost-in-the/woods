# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'release gemspec dependency contract' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, 'woods.gemspec')) }

  def runtime_requirement(name)
    gemspec.runtime_dependencies.find { |dependency| dependency.name == name }.requirement
  end

  # The gemspec derives its release_ref from Woods::VERSION, so both branches of
  # that rule can only be exercised against a different VERSION. Evaluating a
  # substituted lib/woods/version.rb in this process would redefine the real
  # Woods::VERSION for every later example, so each branch is evaluated in a
  # subprocess against a throwaway checkout of the two files the rule reads.
  def metadata_for(version)
    Dir.mktmpdir('woods-gemspec-ref') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'lib/woods'))
      File.write(File.join(dir, 'lib/woods/version.rb'), <<~RUBY)
        module Woods
          VERSION = '#{version}'
        end
      RUBY
      FileUtils.cp(File.join(root, 'woods.gemspec'), File.join(dir, 'woods.gemspec'))
      # Bundler's RUBYOPT hook would load this checkout's real lib/woods/version.rb
      # in the child before the gemspec requires the substituted one, so the child
      # runs outside the bundle.
      clean_env = ENV.keys.grep(/\ABUNDLE_|\ARUBYOPT\z|\AGEM_/).to_h { |key| [key, nil] }
      stdout, stderr, status = Open3.capture3(
        clean_env, Gem.ruby, '--disable-gems', '-e',
        'require "rubygems"; require "json"; ' \
        'print JSON.generate(Gem::Specification.load("woods.gemspec").metadata)',
        chdir: dir
      )
      raise stderr unless status.success?

      JSON.parse(stdout)
    end
  end

  it 'requires patched msgpack 1.8.2 through the 1.x series without admitting 2.0' do
    requirement = runtime_requirement('msgpack')

    expect(requirement).to be_satisfied_by(Gem::Version.new('1.8.2'))
    expect(requirement).to be_satisfied_by(Gem::Version.new('1.99.0'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('1.8.1'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('2.0.0'))
  end

  it 'requires patched JSON 2.x compatible with the supported older Rails encoders' do
    requirement = runtime_requirement('json')

    expect(requirement).to be_satisfied_by(Gem::Version.new('2.19.9'))
    expect(requirement).to be_satisfied_by(Gem::Version.new('2.99.0'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('2.19.8'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('3.0.0'))
  end

  it 'supports Rails 6 through 8 without admitting Rails 9' do
    requirement = runtime_requirement('railties')

    expect(requirement).to be_satisfied_by(Gem::Version.new('6.0.0'))
    expect(requirement).to be_satisfied_by(Gem::Version.new('8.99.0'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('5.2.8'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('9.0.0'))
  end

  it 'points release metadata at main while VERSION carries the alpha development marker' do
    metadata = metadata_for('2.1.0.alpha')

    expect(metadata.fetch('source_code_uri')).to eq('https://github.com/lost-in-the/woods/tree/main')
    expect(metadata.fetch('changelog_uri')).to eq('https://github.com/lost-in-the/woods/blob/main/CHANGELOG.md')
    expect(metadata.fetch('documentation_uri')).to eq('https://github.com/lost-in-the/woods/tree/main/docs')
  end

  it 'pins release metadata to the version tag for beta, rc, and final versions' do
    %w[2.0.0.beta1 2.0.0.rc1 2.0.0].each do |version|
      metadata = metadata_for(version)

      expect(metadata.fetch('source_code_uri')).to eq("https://github.com/lost-in-the/woods/tree/v#{version}")
      expect(metadata.fetch('changelog_uri'))
        .to eq("https://github.com/lost-in-the/woods/blob/v#{version}/CHANGELOG.md")
      expect(metadata.fetch('documentation_uri'))
        .to eq("https://github.com/lost-in-the/woods/tree/v#{version}/docs")
    end
  end

  it 'ships main as the development marker on this branch' do
    expect(Woods::VERSION).to end_with('.alpha')
    expect(gemspec.metadata.fetch('source_code_uri')).to eq('https://github.com/lost-in-the/woods/tree/main')
  end
end
