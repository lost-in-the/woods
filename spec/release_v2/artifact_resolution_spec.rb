# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Companion to release_validator_spec.rb's CI-run-validation coverage: this
# file owns the artifact-identity resolution (Task 10) added on top of that
# contract. Kept separate, with its own fake `gh` and env builders, because
# release_validator_spec.rb is off-limits for this change.
RSpec.describe 'release artifact identity resolution' do
  let(:run_validator) { File.expand_path('../../script/validate-release-run', __dir__) }
  let(:release_sha) { 'a' * 40 }
  let(:artifact_name) { "woods-release-#{release_sha}" }

  def ci_run(overrides = {})
    {
      'id' => 12_345,
      'workflow_id' => 678,
      'conclusion' => 'success',
      'event' => 'push',
      'head_branch' => 'v2.0.0',
      'head_sha' => release_sha,
      'repository' => { 'full_name' => 'lost-in-the/woods' },
      'head_repository' => { 'full_name' => 'lost-in-the/woods' }
    }.merge(overrides)
  end

  def artifact(overrides = {})
    {
      'id' => 987_654,
      'name' => artifact_name,
      'digest' => "sha256:#{'b' * 64}"
    }.merge(overrides)
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
      when %r{/actions/runs/\d+\z} then print ENV.fetch('GH_RUN_JSON')
      when %r{/actions/workflows/ci\.yml\z} then print ENV.fetch('GH_WORKFLOW_JSON')
      else
        warn "unexpected endpoint: #{endpoint}"
        exit 1
      end
    RUBY
    FileUtils.chmod(0o755, gh)
    fake_bin
  end

  def validate_ci_run(run: ci_run, workflow: { 'id' => 678 }, artifacts: [artifact])
    Dir.mktmpdir('woods-artifact-resolution') do |directory|
      env = {
        'PATH' => "#{write_fake_gh(directory)}:#{ENV.fetch('PATH')}",
        'CI_RUN_ID' => '12345',
        'RELEASE_TAG' => 'v2.0.0',
        'GITHUB_REPOSITORY' => 'lost-in-the/woods',
        'GITHUB_OUTPUT' => File.join(directory, 'github-output'),
        'GH_API_LOG' => File.join(directory, 'gh-api.log'),
        'GH_RUN_JSON' => JSON.generate(run),
        'GH_WORKFLOW_JSON' => JSON.generate(workflow),
        'GH_ARTIFACTS_JSON' => JSON.generate('artifacts' => artifacts)
      }

      stdout, stderr, status = Open3.capture3(env, 'ruby', run_validator)
      outputs = File.exist?(env['GITHUB_OUTPUT']) ? File.read(env['GITHUB_OUTPUT']) : ''
      calls = File.exist?(env['GH_API_LOG']) ? File.readlines(env['GH_API_LOG'], chomp: true) : []
      return stdout, stderr, status, outputs, calls
    end
  end

  it 'resolves the run-scoped artifact by name to an immutable id and digest' do
    _stdout, stderr, status, outputs, calls = validate_ci_run

    expect(status).to be_success, stderr
    expect(calls).to include('/repos/lost-in-the/woods/actions/runs/12345/artifacts')
    lines = outputs.lines(chomp: true)
    expect(lines).to include(
      "artifact-name=#{artifact_name}",
      'artifact-id=987654',
      "artifact-digest=sha256:#{'b' * 64}"
    )
  end

  it 'fails closed when no artifact in the run matches the expected name' do
    _stdout, stderr, status, _outputs, _calls = validate_ci_run(artifacts: [artifact('name' => 'unrelated-artifact')])

    expect(status).not_to be_success
    expect(stderr).to include("no artifact named #{artifact_name} exists in CI run 12345")
  end

  it 'fails closed when more than one artifact in the run matches the expected name' do
    _stdout, stderr, status, _outputs, _calls = validate_ci_run(
      artifacts: [artifact, artifact('id' => 987_655)]
    )

    expect(status).not_to be_success
    expect(stderr).to include("2 artifacts named #{artifact_name} exist in CI run 12345, expected exactly one")
  end

  it 'fails closed rather than trusting the co-shipped .sha256 when the API omits a digest' do
    _stdout, stderr, status, _outputs, _calls = validate_ci_run(artifacts: [artifact('digest' => nil)])

    expect(status).not_to be_success
    expect(stderr).to include("artifact #{artifact_name} (id 987654) in CI run 12345 has no digest")
    expect(stderr).to include('refusing to fall back to the artifact-internal .sha256 file')
  end
end
