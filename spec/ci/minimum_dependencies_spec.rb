# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'yaml'

RSpec.describe 'Minimum runtime dependency contract' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, 'woods.gemspec')) }

  it 'pins every advertised direct runtime floor exactly without development dependencies' do
    previous = ENV.fetch('WOODS_MINIMUM_VERSION', nil)
    ENV['WOODS_MINIMUM_VERSION'] = gemspec.version.to_s
    dependencies = Bundler::Dsl.evaluate(File.join(root, 'gemfiles/minimum_runtime.gemfile'), nil, {}).dependencies
    pins = dependencies.to_h { |dependency| [dependency.name, dependency.requirement] }
    expect(pins.keys.sort).to eq((gemspec.runtime_dependencies.map(&:name) + ['woods']).sort)
    gemspec.runtime_dependencies.each do |dependency|
      # requirements is an Array of tuples, not a Hash (HashSlice does not apply).
      bounds = dependency.requirement.requirements.select { |operator, _| %w[>= ~> =].include?(operator) } # rubocop:disable Style/HashSlice
      expect(bounds).not_to be_empty
      expect(pins.fetch(dependency.name).requirements).to eq([['=', bounds.map(&:last).max]])
    end
    expect(pins.fetch('woods')).to eq(Gem::Requirement.new("= #{gemspec.version}"))
  ensure
    ENV['WOODS_MINIMUM_VERSION'] = previous
  end

  it 'runs the installed-artifact probe independently of the development bundle on the Ruby floor' do
    workflow = YAML.load_file(File.join(root, '.github/workflows/ci.yml'))
    job = workflow.fetch('jobs').fetch('minimum-dependencies')
    setup = job.fetch('steps').find { |step| step['uses'].to_s.start_with?('ruby/setup-ruby@') }.fetch('with')
    expect(setup).to include('ruby-version' => '3.0', 'bundler' => '2.5.23')
    expect(setup['bundler-cache']).not_to be(true)
    expect(job.fetch('steps').map { |step| step['run'] }.compact).to eq(['ruby script/test-minimum-dependencies'])
    expect(job.fetch('steps').last.fetch('with')).to include('path' => 'tmp/minimum-dependencies/')
  end
end
