# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'Maintenance CI publication boundary' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:ci) { YAML.load_file(File.join(root, '.github/workflows/ci.yml')) }

  it 'tests maintenance PRs and only the allowlisted maintenance tag' do
    triggers = ci.fetch('on') { ci.fetch(true) }
    expect(triggers.dig('pull_request', 'branches')).to include('release/1.6.3')
    expect(triggers.dig('push', 'branches')).to eq(['release/1.6.3'])
    expect(triggers.dig('push', 'tags')).to eq(['v1.6.3'])
  end

  it 'retains the real credential rotation gate in every booted Rails row' do
    job = ci.fetch('jobs').fetch('rails-matrix')
    expect(job.dig('strategy', 'matrix', 'include').size).to eq(7)
    expect(job.fetch('steps').map { |step| step['run'] }).to include(
      'bundle exec rspec spec/integration/console_credential_rotation_spec.rb'
    )
  end

  it 'builds once and reuses the same immutable artifact in both package rows' do
    build = ci.fetch('jobs').fetch('build')
    upload = build.fetch('steps').find { |step| step['id'] == 'upload' }
    expect(upload.dig('with', 'name')).to eq('woods-release-${{ github.sha }}')
    expect(upload.dig('with', 'path')).to include('.sha256')
    package = ci.fetch('jobs').fetch('maintenance-package')
    expect(package['needs']).to eq('build')
    expect(package.dig('strategy', 'matrix', 'include').map { |row| [row['ruby'], row['rails']] })
      .to eq([%w[3.0 6.0], %w[4.0 8.1]])
    expect(package.dig('strategy', 'matrix', 'include').first.fetch('mcp')).to eq('0.23.0')
    expect(package.fetch('steps').last.dig('env', 'WOODS_EXPECT_MCP_VERSION')).to eq('${{ matrix.mcp }}')
    download = package.fetch('steps').find { |step| step['uses'].to_s.start_with?('actions/download-artifact@') }
    expect(download.dig('with', 'artifact-ids')).to eq('${{ needs.build.outputs.artifact-id }}')
    expect(download.dig('with', 'merge-multiple')).to be true
    command = package.fetch('steps').last.fetch('run')
    expect(command).to include('--options /dev/null spec/integration/maintenance_packaged_gem_spec.rb')
    expect(command).not_to include('-Ilib', 'bundle exec')
  end

  it 'has no legacy publishing trigger, write credential, or publishing action' do
    workflow = File.read(File.join(root, '.github/workflows/release.yml'))
    parsed = YAML.safe_load(workflow)
    triggers = parsed.fetch('on') { parsed.fetch(true) }
    expect(triggers.keys).to eq(['workflow_dispatch'])
    expect(parsed['permissions']).to eq('contents' => 'read')
    expect(workflow).not_to match(/gem push|id-token:|contents: write|configure-rubygems|action-gh-release/)
  end
end
