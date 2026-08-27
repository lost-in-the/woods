# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Companion to release_validator_spec.rb's CI-run-validation coverage: this
# file owns the trusted-CI-workflow-contract check (Task 10) added on top of
# that contract. Kept separate, with its own fake `gh` and env builders,
# because release_validator_spec.rb is off-limits for this change. A run
# belonging to .github/workflows/ci.yml (matched by workflow_id) only proves
# the run executed *some* revision of that file at that path - a candidate
# ref can edit ci.yml down to a handful of jobs without changing either.
RSpec.describe 'release CI workflow contract' do
  let(:run_validator) { File.expand_path('../../script/validate-release-run', __dir__) }
  let(:release_sha) { 'a' * 40 }
  let(:artifact_name) { "woods-release-#{release_sha}" }

  def ci_run(overrides = {})
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
    }.merge(overrides)
  end

  def full_job_set
    [
      { 'name' => 'Unit specs (Ruby 3.0)', 'conclusion' => 'success' },
      { 'name' => 'Unit specs (Ruby 4.0)', 'conclusion' => 'success' },
      { 'name' => 'Booted extraction (Ruby 4.0 / Rails 8.1)', 'conclusion' => 'success' },
      { 'name' => 'Live backends (pgvector + Qdrant + Solid Cache)', 'conclusion' => 'success' },
      { 'name' => 'MCP transports (official clients)', 'conclusion' => 'success' },
      { 'name' => 'coverage', 'conclusion' => 'success' },
      { 'name' => 'security', 'conclusion' => 'success' },
      { 'name' => 'lint', 'conclusion' => 'success' },
      { 'name' => 'build', 'conclusion' => 'success' }
    ]
  end

  def artifacts_json
    JSON.generate('artifacts' => [{ 'id' => 987_654, 'name' => artifact_name, 'digest' => "sha256:#{'b' * 64}" }])
  end

  def environment_json(protected_environment: true)
    JSON.generate(
      'protection_rules' => protected_environment ? [{ 'type' => 'required_reviewers' }] : [],
      'can_admins_bypass' => false
    )
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

  def validate_ci_run(run: ci_run,
                      workflow: { 'id' => 678, 'path' => '.github/workflows/ci.yml', 'name' => 'CI' },
                      jobs: full_job_set)
    Dir.mktmpdir('woods-ci-workflow-contract') do |directory|
      env = {
        'PATH' => "#{write_fake_gh(directory)}:#{ENV.fetch('PATH')}",
        'CI_RUN_ID' => '12345',
        'RELEASE_TAG' => 'v2.0.0',
        'GITHUB_REPOSITORY' => 'lost-in-the/woods',
        'GITHUB_OUTPUT' => File.join(directory, 'github-output'),
        'GH_API_LOG' => File.join(directory, 'gh-api.log'),
        'GH_RUN_JSON' => JSON.generate(run),
        'GH_WORKFLOW_JSON' => JSON.generate(workflow),
        'GH_JOBS_JSON' => JSON.generate('jobs' => jobs),
        'GH_ARTIFACTS_JSON' => artifacts_json,
        'GH_ENVIRONMENT_JSON' => environment_json
      }

      stdout, stderr, status = Open3.capture3(env, 'ruby', run_validator)
      return stdout, stderr, status
    end
  end

  it 'passes when the run executed every job the trusted default-branch CI contract requires' do
    _stdout, stderr, status = validate_ci_run

    expect(status).to be_success, stderr
  end

  it 'rejects a run whose workflow file is not at the trusted CI path' do
    _stdout, stderr, status = validate_ci_run(run: ci_run('path' => '.github/workflows/reduced-ci.yml'))

    expect(status).not_to be_success
    expect(stderr).to include('ran workflow .github/workflows/reduced-ci.yml')
    expect(stderr).to include('expected .github/workflows/ci.yml')
  end

  it 'rejects a run whose workflow definition path or name has drifted from the trusted contract' do
    _stdout, stderr, status = validate_ci_run(
      workflow: { 'id' => 678, 'path' => '.github/workflows/ci-fast.yml', 'name' => 'CI' }
    )

    expect(status).not_to be_success
    expect(stderr).to include('workflow definition path is .github/workflows/ci-fast.yml')
  end

  it 'rejects a reduced candidate workflow missing a required job' do
    reduced_jobs = full_job_set.reject { |job| job['name'] == 'security' }

    _stdout, stderr, status = validate_ci_run(jobs: reduced_jobs)

    expect(status).not_to be_success
    expect(stderr).to include('no job matching required CI contract job "security"')
  end

  it 'rejects a required job that ran but did not succeed' do
    failed_jobs = full_job_set.map { |job| job['name'] == 'lint' ? job.merge('conclusion' => 'failure') : job }

    _stdout, stderr, status = validate_ci_run(jobs: failed_jobs)

    expect(status).not_to be_success
    expect(stderr).to include('job "lint" concluded failure')
    expect(stderr).to include('required CI contract job "lint"')
  end
end
