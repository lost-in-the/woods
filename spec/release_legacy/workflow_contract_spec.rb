# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'Maintenance CI publication boundary' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:ci) { YAML.load_file(File.join(root, '.github/workflows/ci.yml')) }

  it 'tests maintenance PRs and only the allowlisted maintenance tag' do
    triggers = ci.fetch('on') { ci.fetch(true) }
    expect(triggers.dig('pull_request', 'branches')).to include('release/1.6.4')
    expect(triggers.dig('push', 'branches')).to eq(['release/1.6.4'])
    expect(triggers.dig('push', 'tags')).to eq(['v1.6.4'])
  end

  it 'retains the real credential rotation gate in every booted Rails row' do
    job = ci.fetch('jobs').fetch('rails-matrix')
    expect(job.dig('strategy', 'matrix', 'include').size).to eq(7)
    expect(job.fetch('steps').map { |step| step['run'] }).to include(
      'bundle exec rspec spec/integration/console_credential_rotation_spec.rb'
    )
  end

  it 'runs every booted Console and integration contract in its own process in every Rails row' do
    job = ci.fetch('jobs').fetch('rails-matrix')
    expect(job.dig('env', 'WOODS_RUN_BOOTED_APP')).to eq('1')
    expect(job.dig('env', 'BUNDLE_GEMFILE')).to eq('gemfiles/rails_${{ matrix.rails }}.gemfile')
    booted_specs = Dir.chdir(root) do
      Dir['spec/{console,integration}/**/*_spec.rb'].select do |path|
        File.read(path).match?(/^RSpec\.describe.*:booted_app/)
      end
    end
    booted_specs.each do |path|
      step = job.fetch('steps').find { |entry| entry['run'] == "bundle exec rspec #{path}" }
      expect(step).not_to be_nil, "#{path} must run alone in the Rails matrix"
      expect(step).not_to have_key('if')
    end
  end

  it 'runs typed policy in every Rails row and real PostgreSQL/MySQL in the maintenance gate' do
    commands = ci.fetch('jobs').fetch('rails-matrix').fetch('steps').filter_map { |step| step['run'] }
    expect(commands).to include('bundle exec rspec spec/integration/console_typed_eav_policy_spec.rb')
    job = ci.fetch('jobs').fetch('maintenance-security-backends')
    expect(job.fetch('name')).to eq('Maintenance security backends')
    expect(job.fetch('services').keys).to contain_exactly('postgres', 'mysql')
    expect(job.dig('env', 'WOODS_RUN_MAINTENANCE_SQL_BACKENDS')).to eq('1')
    expect(job.dig('env', 'BUNDLE_GEMFILE')).to eq('gemfiles/console_backends.gemfile')
    expect(job.fetch('steps').last.fetch('run'))
      .to eq('bundle exec rspec spec/integration/console_sql_dialects_spec.rb')
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
