# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'mcp'

RSpec.describe 'MCP conformance dependencies' do
  let(:root) { File.expand_path('../..', __dir__) }

  it 'declares the documented SDK range and resolves a compatible release' do
    gemspec = Gem::Specification.load(File.join(root, 'woods.gemspec'))
    dependency = gemspec.runtime_dependencies.find { |entry| entry.name == 'mcp' }

    # The public contract (CHANGELOG, CLAUDE.md, docs/) is the range. CI can
    # resolve any compatible 1.x release, so pin behavior through conformance
    # specs instead of pinning this assertion to one SDK patch/minor version.
    expect(dependency.requirement.to_s).to eq('>= 1.2, < 2.0')
    expect(dependency.requirement).to be_satisfied_by(Gem::Version.new(MCP::VERSION))

    version = Gem::Version.new(MCP::VERSION)
    expect(version).to be >= Gem::Version.new('1.2.0')
    expect(version).to be < Gem::Version.new('2.0.0')
  end

  it 'pins official Inspector v2 with the verified package integrity' do
    package = JSON.parse(File.read(File.join(root, 'package.json')))
    lock = JSON.parse(File.read(File.join(root, 'package-lock.json')))
    inspector = lock.dig('packages', 'node_modules/@modelcontextprotocol/inspector')

    expect(package.dig('devDependencies', '@modelcontextprotocol/inspector')).to eq('2.2.0')
    expect(inspector).to include(
      'version' => '2.2.0',
      'integrity' => 'sha512-IUyZsx6XzSr1Rl3xScqkOtqAwCsguI6kdc+/6rP0efKL/O22/5ougEkhVxudN7yIVGiSd49FZKhUk47/iMJRxA=='
    )
  end
end
