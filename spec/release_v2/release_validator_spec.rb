# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'release validation' do
  let(:validator) { File.expand_path('../../script/validate-release', __dir__) }
  let(:run_validator) { File.expand_path('../../script/validate-release-run', __dir__) }
  let(:tag_verifier) { File.expand_path('../../script/verify-release-tag', __dir__) }
  let(:release_sha) { 'a' * 40 }

  def git(*args, chdir:)
    output, status = Open3.capture2e('git', *args, chdir: chdir)
    raise output unless status.success?

    output.strip
  end

  def write_release_files(repository, changelog: "## [2.0.0] - 2026-08-19\n")
    FileUtils.mkdir_p(File.join(repository, 'lib/woods'))
    File.write(File.join(repository, 'lib/woods/version.rb'), <<~RUBY)
      module Woods
        VERSION = '2.0.0'
      end
    RUBY
    File.write(File.join(repository, 'CHANGELOG.md'), changelog)
  end

  def build_repository(changelog: "## [2.0.0] - 2026-08-19\n", tag_type: :lightweight)
    Dir.mktmpdir('woods-release-validator') do |repository|
      git('init', '-b', 'main', chdir: repository)
      git('config', 'user.email', 'release-test@example.invalid', chdir: repository)
      git('config', 'user.name', 'Release Test', chdir: repository)
      write_release_files(repository, changelog: changelog)
      git('add', '.', chdir: repository)
      git('commit', '-m', 'release candidate', chdir: repository)
      git('update-ref', 'refs/remotes/origin/main', 'HEAD', chdir: repository)
      tag_args = tag_type == :annotated ? ['-a', 'v2.0.0', '-m', 'release v2.0.0'] : ['v2.0.0']
      git('tag', *tag_args, chdir: repository)
      yield repository
    end
  end

  def add_origin(repository)
    remote = File.join(repository, '.git', 'release-origin.git')
    git('init', '--bare', remote, chdir: repository)
    git('remote', 'add', 'origin', remote, chdir: repository)
    git('push', 'origin', 'main', 'refs/tags/v2.0.0', chdir: repository)
  end

  def validate(repository, tag: 'v2.0.0', sha: nil, published_versions: [])
    sha ||= git('rev-parse', 'HEAD', chdir: repository)
    env = {
      'RELEASE_TAG' => tag,
      'RELEASE_SHA' => sha,
      'RELEASE_MAIN_REF' => 'refs/remotes/origin/main',
      'RUBYGEMS_VERSIONS_JSON' => JSON.generate(published_versions)
    }

    Open3.capture3(env, validator, chdir: repository)
  end

  def verify_remote_tag(repository, sha:)
    env = {
      'RELEASE_REMOTE' => 'origin',
      'RELEASE_SHA' => sha,
      'RELEASE_TAG' => 'v2.0.0'
    }

    Open3.capture3(env, 'ruby', tag_verifier, chdir: repository)
  end

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

  def write_fake_gh(directory)
    fake_bin = File.join(directory, 'bin')
    FileUtils.mkdir_p(fake_bin)
    gh = File.join(fake_bin, 'gh')
    File.write(gh, <<~'RUBY')
      #!/usr/bin/env ruby
      endpoint = ARGV.fetch(-1)
      File.open(ENV.fetch('GH_API_LOG'), 'a') { |file| file.puts(endpoint) }
      case endpoint
      when %r{/actions/runs/} then print ENV.fetch('GH_RUN_JSON')
      when %r{/actions/workflows/ci\.yml\z} then print ENV.fetch('GH_WORKFLOW_JSON')
      else
        warn "unexpected endpoint: #{endpoint}"
        exit 1
      end
    RUBY
    FileUtils.chmod(0o755, gh)
    fake_bin
  end

  def ci_run_env(directory, fake_bin, run, workflow)
    {
      'PATH' => "#{fake_bin}:#{ENV.fetch('PATH')}",
      'CI_RUN_ID' => '12345',
      'RELEASE_TAG' => 'v2.0.0',
      'GITHUB_REPOSITORY' => 'lost-in-the/woods',
      'GITHUB_OUTPUT' => File.join(directory, 'github-output'),
      'GH_API_LOG' => File.join(directory, 'gh-api.log'),
      'GH_RUN_JSON' => JSON.generate(run),
      'GH_WORKFLOW_JSON' => JSON.generate(workflow)
    }
  end

  def validate_ci_run(run: ci_run, workflow: { 'id' => 678 }, env: {})
    Dir.mktmpdir('woods-release-run-validator') do |directory|
      command_env = ci_run_env(directory, write_fake_gh(directory), run, workflow).merge(env)
      command_env.delete_if { |_key, value| value.nil? }

      stdout, stderr, status = Open3.capture3(command_env, 'ruby', run_validator)
      outputs = File.exist?(command_env['GITHUB_OUTPUT']) ? File.read(command_env['GITHUB_OUTPUT']) : ''
      calls = File.exist?(command_env['GH_API_LOG']) ? File.readlines(command_env['GH_API_LOG'], chomp: true) : []
      return stdout, stderr, status, outputs, calls
    end
  end

  it 'queries the named CI run and emits its exact SHA-scoped artifact context' do
    _stdout, stderr, status, outputs, calls = validate_ci_run

    expect(status).to be_success, stderr
    expect(calls).to eq(
      %w[
        /repos/lost-in-the/woods/actions/runs/12345
        /repos/lost-in-the/woods/actions/workflows/ci.yml
      ]
    )
    expect(outputs.lines(chomp: true)).to contain_exactly(
      "release-sha=#{release_sha}",
      'tag=v2.0.0',
      "artifact-name=woods-release-#{release_sha}"
    )
  end

  it 'rejects missing dispatch inputs before querying GitHub' do
    {
      'CI_RUN_ID' => 'CI_RUN_ID is required',
      'RELEASE_TAG' => 'RELEASE_TAG is required'
    }.each do |name, message|
      _stdout, stderr, status, _outputs, calls = validate_ci_run(env: { name => nil })

      expect(status).not_to be_success
      expect(stderr).to include(message)
      expect(calls).to be_empty
    end
  end

  it 'rejects an invalid CI run ID before querying GitHub' do
    _stdout, stderr, status, _outputs, calls = validate_ci_run(env: { 'CI_RUN_ID' => 'latest' })

    expect(status).not_to be_success
    expect(stderr).to include('CI_RUN_ID must be a positive integer')
    expect(calls).to be_empty
  end

  it 'rejects an invalid release tag before querying GitHub' do
    _stdout, stderr, status, _outputs, calls = validate_ci_run(env: { 'RELEASE_TAG' => '../../main' })

    expect(status).not_to be_success
    expect(stderr).to include('RELEASE_TAG must be a version tag')
    expect(calls).to be_empty
  end

  it 'rejects CI run data that does not describe the exact successful tag push' do
    invalid_runs = [
      [ci_run('id' => 99_999), 'returned run ID 99999, expected 12345'],
      [ci_run('workflow_id' => 999), 'does not belong to .github/workflows/ci.yml'],
      [ci_run('conclusion' => 'failure'), 'conclusion is failure, expected success'],
      [ci_run('event' => 'pull_request'), 'event is pull_request, expected push'],
      [ci_run('head_branch' => 'v1.6.1'), 'tested ref is v1.6.1, expected v2.0.0'],
      [ci_run('head_sha' => 'short'), 'head SHA is not a full Git SHA'],
      [ci_run('head_repository' => { 'full_name' => 'fork/woods' }), 'head repository is fork/woods'],
      [ci_run('repository' => { 'full_name' => 'fork/woods' }), 'repository is fork/woods']
    ]

    invalid_runs.each do |run, message|
      _stdout, stderr, status, _outputs, _calls = validate_ci_run(run: run)

      expect(status).not_to be_success, message
      expect(stderr).to include(message)
    end
  end

  it 'rejects a stale named CI run after the release tag moves to a newer SHA' do
    build_repository do |repository|
      stale_sha = git('rev-parse', 'HEAD', chdir: repository)
      git('commit', '--allow-empty', '-m', 'new tagged commit', chdir: repository)
      current_sha = git('rev-parse', 'HEAD', chdir: repository)
      git('tag', '-f', 'v2.0.0', chdir: repository)
      git('update-ref', 'refs/remotes/origin/main', current_sha, chdir: repository)
      git('checkout', '--detach', stale_sha, chdir: repository)

      _stdout, context_stderr, context_status, outputs, _calls = validate_ci_run(
        run: ci_run('head_sha' => stale_sha)
      )
      expect(context_status).to be_success, context_stderr
      output = outputs.lines(chomp: true).to_h { |line| line.split('=', 2) }

      _validator_stdout, validator_stderr, validator_status = validate(
        repository,
        tag: output.fetch('tag'),
        sha: output.fetch('release-sha')
      )

      expect(validator_status).not_to be_success
      expect(validator_stderr).to include("v2.0.0 resolves to #{current_sha}, not release SHA #{stale_sha}")
    end
  end

  it 'accepts v2.0.0 at the exact main-reachable SHA with its dated changelog entry' do
    build_repository do |repository|
      stdout, stderr, status = validate(repository)

      expect(status).to be_success, stderr
      expect(stdout).to include('v2.0.0')
      expect(stdout).to include('2026-08-19')
    end
  end

  it 'rejects a tag that does not exactly match the gem version' do
    build_repository do |repository|
      _stdout, stderr, status = validate(repository, tag: 'v2.0.1')

      expect(status).not_to be_success
      expect(stderr).to include('must equal v2.0.0')
    end
  end

  it 'rejects a release without the matching dated changelog section' do
    build_repository(changelog: "## [Next] - Unreleased\n") do |repository|
      _stdout, stderr, status = validate(repository)

      expect(status).not_to be_success
      expect(stderr).to include('dated CHANGELOG.md section')
    end
  end

  it 'rejects a tag SHA that is not reachable from main' do
    build_repository do |repository|
      git('checkout', '--orphan', 'release-side', chdir: repository)
      write_release_files(repository)
      git('add', '.', chdir: repository)
      git('commit', '-m', 'unreachable release', chdir: repository)
      git('tag', '-d', 'v2.0.0', chdir: repository)
      git('tag', 'v2.0.0', chdir: repository)

      _stdout, stderr, status = validate(repository)

      expect(status).not_to be_success
      expect(stderr).to include('not reachable from')
    end
  end

  it 'rejects an already-published gem version' do
    build_repository do |repository|
      versions = [{ 'number' => '2.0.0' }, { 'number' => '1.6.1' }]
      _stdout, stderr, status = validate(repository, published_versions: versions)

      expect(status).not_to be_success
      expect(stderr).to include('already published')
    end
  end

  it 'accepts current lightweight and annotated remote tags at the tested SHA' do
    %i[lightweight annotated].each do |tag_type|
      build_repository(tag_type: tag_type) do |repository|
        add_origin(repository)
        release_sha = git('rev-parse', 'HEAD', chdir: repository)

        stdout, stderr, status = verify_remote_tag(repository, sha: release_sha)

        expect(status).to be_success, "#{tag_type}: #{stderr}"
        expect(stdout).to include("v2.0.0 at #{release_sha}")
      end
    end
  end

  it 'blocks publication when the remote tag moves after initial validation' do
    build_repository(tag_type: :annotated) do |repository|
      add_origin(repository)
      release_sha = git('rev-parse', 'HEAD', chdir: repository)
      _stdout, initial_stderr, initial_status = validate(repository, sha: release_sha)
      expect(initial_status).to be_success, initial_stderr

      git('commit', '--allow-empty', '-m', 'later commit', chdir: repository)
      moved_sha = git('rev-parse', 'HEAD', chdir: repository)
      git('push', 'origin', ':refs/tags/v2.0.0', chdir: repository)
      git('tag', '-d', 'v2.0.0', chdir: repository)
      git('tag', 'v2.0.0', chdir: repository)
      git('push', 'origin', 'refs/tags/v2.0.0', chdir: repository)
      git('checkout', '--detach', release_sha, chdir: repository)

      _stdout, stderr, status = verify_remote_tag(repository, sha: release_sha)

      expect(status).not_to be_success
      expect(stderr).to include("v2.0.0 resolves to #{moved_sha}, not release SHA #{release_sha}")
    end
  end

  it 'blocks publication when the checkout is not the tested SHA' do
    build_repository do |repository|
      add_origin(repository)
      release_sha = git('rev-parse', 'HEAD', chdir: repository)
      git('commit', '--allow-empty', '-m', 'different checkout', chdir: repository)
      head_sha = git('rev-parse', 'HEAD', chdir: repository)

      _stdout, stderr, status = verify_remote_tag(repository, sha: release_sha)

      expect(status).not_to be_success
      expect(stderr).to include("checked-out HEAD #{head_sha} does not equal release SHA #{release_sha}")
    end
  end
end
