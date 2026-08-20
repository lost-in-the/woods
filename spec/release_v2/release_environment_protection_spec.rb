# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Companion to release_validator_spec.rb's CI-run-validation coverage: this
# file owns the live 'release' environment protection check (Task 10).
# Kept separate, with its own fake `gh` and env builders, because
# release_validator_spec.rb is off-limits for this change. This script
# cannot and must not change the live environment's settings - it can only
# detect an absent gate and refuse to hand the operator a green light.
RSpec.describe 'release environment protection' do
  let(:run_validator) { File.expand_path('../../script/validate-release-run', __dir__) }
  let(:release_sha) { 'a' * 40 }
  let(:artifact_name) { "woods-release-#{release_sha}" }

  def ci_run
    {
      'id' => 12_345,
      'workflow_id' => 678,
      'path' => '.github/workflows/ci.yml',
      'conclusion' => 'success',
      'event' => 'push',
      'head_branch' => 'v2.0.0',
      'head_sha' => release_sha,
      'repository' => { 'full_name' => 'lost-in-the/woods' },
      'head_repository' => { 'full_name' => 'lost-in-the/woods' }
    }
  end

  def matrixed_job_names
    {
      'test' => 'Unit specs (Ruby 4.0)',
      'live-backends' => 'Live backends (pgvector + Qdrant + Solid Cache)',
      'http-transport' => 'MCP transports (official clients)'
    }
  end

  def full_job_set
    %w[test live-backends http-transport coverage security lint build].map do |id|
      { 'name' => matrixed_job_names.fetch(id, id), 'conclusion' => 'success' }
    end
  end

  def artifacts_json
    JSON.generate('artifacts' => [{ 'id' => 987_654, 'name' => artifact_name, 'digest' => "sha256:#{'b' * 64}" }])
  end

  def write_fake_gh(directory)
    fake_bin = File.join(directory, 'bin')
    FileUtils.mkdir_p(fake_bin)
    gh = File.join(fake_bin, 'gh')
    File.write(gh, <<~'RUBY')
      #!/usr/bin/env ruby
      endpoint = ARGV.fetch(-1)
      File.open(ENV.fetch('GH_API_LOG'), 'a') { |file| file.puts(endpoint) }
      case endpoint
      when %r{/actions/runs/\d+/artifacts\z} then print ENV.fetch('GH_ARTIFACTS_JSON')
      when %r{/actions/runs/\d+/jobs\z} then print ENV.fetch('GH_JOBS_JSON')
      when %r{/actions/runs/\d+\z} then print ENV.fetch('GH_RUN_JSON')
      when %r{/actions/workflows/ci\.yml\z} then print ENV.fetch('GH_WORKFLOW_JSON')
      when %r{/environments/release\z} then print ENV.fetch('GH_ENVIRONMENT_JSON')
      else
        warn "unexpected endpoint: #{endpoint}"
        exit 1
      end
    RUBY
    FileUtils.chmod(0o755, gh)
    fake_bin
  end

  def validate_ci_run(environment:)
    Dir.mktmpdir('woods-environment-protection') do |directory|
      env = {
        'PATH' => "#{write_fake_gh(directory)}:#{ENV.fetch('PATH')}",
        'CI_RUN_ID' => '12345',
        'RELEASE_TAG' => 'v2.0.0',
        'GITHUB_REPOSITORY' => 'lost-in-the/woods',
        'GITHUB_OUTPUT' => File.join(directory, 'github-output'),
        'GH_API_LOG' => File.join(directory, 'gh-api.log'),
        'GH_RUN_JSON' => JSON.generate(ci_run),
        'GH_WORKFLOW_JSON' => JSON.generate('id' => 678, 'path' => '.github/workflows/ci.yml', 'name' => 'CI'),
        'GH_JOBS_JSON' => JSON.generate('jobs' => full_job_set),
        'GH_ARTIFACTS_JSON' => artifacts_json,
        'GH_ENVIRONMENT_JSON' => JSON.generate(environment)
      }

      stdout, stderr, status = Open3.capture3(env, 'ruby', run_validator)
      calls = File.exist?(env['GH_API_LOG']) ? File.readlines(env['GH_API_LOG'], chomp: true) : []
      return stdout, stderr, status, calls
    end
  end

  it 'passes when the live release environment has a protection rule and no admin bypass' do
    _stdout, stderr, status, calls = validate_ci_run(
      environment: { 'protection_rules' => [{ 'type' => 'required_reviewers' }], 'can_admins_bypass' => false }
    )

    expect(status).to be_success, stderr
    expect(calls).to include('/repos/lost-in-the/woods/environments/release')
  end

  it 'fails closed when the live release environment has no protection rules' do
    _stdout, stderr, status, _calls = validate_ci_run(
      environment: { 'protection_rules' => [], 'can_admins_bypass' => false }
    )

    expect(status).not_to be_success
    expect(stderr).to include("live 'release' environment has no protection rules configured")
    expect(stderr).to include('request approval before publishing')
  end

  it 'fails closed when the live release environment permits administrator bypass' do
    _stdout, stderr, status, _calls = validate_ci_run(
      environment: { 'protection_rules' => [{ 'type' => 'required_reviewers' }], 'can_admins_bypass' => true }
    )

    expect(status).not_to be_success
    expect(stderr).to include("live 'release' environment allows administrators to bypass protection rules")
    expect(stderr).to include('request approval before publishing')
  end
end
