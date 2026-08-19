# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'open3'
require 'tmpdir'
require 'yaml'

module ReleaseWorkflowSpec
  Candidate = Struct.new(:tag, :sha, :artifact_sha256, keyword_init: true)
end

RSpec.describe 'release workflow contract' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:ci) { YAML.safe_load_file(File.join(root, '.github/workflows/ci.yml'), aliases: true) }
  let(:release) { YAML.safe_load_file(File.join(root, '.github/workflows/release.yml'), aliases: true) }
  let(:release_trigger) { release.fetch('on') { release.fetch(true) } }

  def steps(job)
    job.fetch('steps')
  end

  def run_commands(job)
    steps(job).filter_map { |step| step['run'] }.join("\n")
  end

  def download_steps(job)
    steps(job).select { |step| step.fetch('uses', '').start_with?('actions/download-artifact@') }
  end

  def concurrency_group_for(candidate)
    template = release.dig('jobs', 'publish', 'concurrency', 'group')
    template.gsub('${{ needs.release-context.outputs.tag }}', candidate.tag)
            .gsub('${{ needs.release-context.outputs.release-sha }}', candidate.sha)
  end

  def latest_pending_transition(running:, pending:, incoming:)
    same_group = concurrency_group_for(pending) == concurrency_group_for(incoming)
    return { running: running, pending: pending, replaced: nil } unless same_group

    { running: running, pending: incoming, replaced: pending }
  end

  def pre_push_verifier_allows?(candidate, current_remote_tag_sha:)
    candidate.sha == current_remote_tag_sha
  end

  it 'runs full CI for version tags before the release workflow can start' do
    ci_trigger = ci.fetch('on') { ci.fetch(true) }

    expect(ci_trigger.dig('push', 'tags')).to contain_exactly('v*')
    expect(release_trigger.dig('workflow_run', 'workflows')).to contain_exactly('CI')
    expect(release_trigger.dig('workflow_run', 'types')).to contain_exactly('completed')
  end

  it 'gates release context on successful full CI for its exact head SHA' do
    context = release.fetch('jobs').fetch('release-context')

    expect(context.fetch('if')).to include("workflow_run.conclusion == 'success'")
    expect(run_commands(context)).to include('github.event.workflow_run.head_sha')
    expect(run_commands(context)).to include('script/validate-release')
  end

  it 'builds exactly one strict artifact in CI and stores it under the exact SHA' do
    ci_build = ci.fetch('jobs').fetch('build')
    all_jobs = ci.fetch('jobs').values + release.fetch('jobs').values
    all_commands = all_jobs.map { |job| run_commands(job) }.join("\n")
    upload = steps(ci_build).find { |step| step.fetch('uses', '').start_with?('actions/upload-artifact@') }

    expect(all_commands.scan('gem build').length).to eq(1)
    expect(run_commands(ci_build)).to include('gem build --strict')
    expect(run_commands(ci_build)).to include('sha256sum')
    expect(run_commands(ci_build)).to include('ARTIFACT_NAME="woods-release-${GITHUB_SHA}"')
    expect(upload).to be_a(Hash)
    expect(upload.fetch('with').fetch('name')).to eq('${{ steps.artifact.outputs.artifact-name }}')
    expect(release.fetch('jobs')).not_to have_key('build')
  end

  it 'rebuilds identical artifact bytes for equivalent CI reruns of one SHA' do
    ci_build = ci.fetch('jobs').fetch('build')
    setup = steps(ci_build).find { |step| step.fetch('uses', '').start_with?('ruby/setup-ruby@') }
    commands = run_commands(ci_build)

    expect(setup.dig('with', 'ruby-version')).to eq('3.3.10')
    expect(commands).to include('export SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$GITHUB_SHA")"')

    Dir.mktmpdir('woods-reproducible-gem') do |directory|
      epoch, status = Open3.capture2e('git', 'show', '-s', '--format=%ct', 'HEAD', chdir: root)
      expect(status).to be_success, epoch
      artifacts = %w[first.gem second.gem].map do |name|
        path = File.join(directory, name)
        output, build_status = Open3.capture2e(
          { 'SOURCE_DATE_EPOCH' => epoch.strip },
          'gem', 'build', '--strict', '--output', path, 'woods.gemspec', chdir: root
        )
        expect(build_status).to be_success, output
        sleep 1
        path
      end

      expect(artifacts.map { |path| Digest::SHA256.file(path).hexdigest }.uniq.length).to eq(1)
    end
  end

  it 'downloads only the triggering CI run artifact identified by its run ID and SHA' do
    jobs = release.fetch('jobs')

    expect(run_commands(jobs.fetch('release-context'))).to include(
      'artifact-name=woods-release-${SHA}'
    )

    %w[package-test publish].each do |job_name|
      downloads = download_steps(jobs.fetch(job_name))
      expect(downloads.length).to eq(1), job_name
      inputs = downloads.fetch(0).fetch('with')
      expect(inputs.fetch('name')).to eq('${{ needs.release-context.outputs.artifact-name }}')
      expect(inputs.fetch('run-id')).to eq('${{ github.event.workflow_run.id }}')
      expect(inputs.fetch('github-token')).to eq('${{ github.token }}')
      expect(inputs.fetch('repository')).to eq('${{ github.repository }}')
    end
  end

  it 'tests the uploaded artifact on the Ruby floor and latest lanes before publishing' do
    jobs = release.fetch('jobs')
    package_test = jobs.fetch('package-test')

    expect(package_test.fetch('needs')).to eq('release-context')
    expect(package_test.dig('strategy', 'matrix', 'include')).to include(
      a_hash_including('ruby' => '3.0'),
      a_hash_including('ruby' => '4.0')
    )
    expect(steps(package_test)).to include(
      a_hash_including('uses' => a_string_starting_with('actions/download-artifact@'))
    )
    expect(run_commands(package_test)).to include('spec/integration/packaged_gem_spec.rb')
    artifact_install = 'gem install --no-document "dist/${{ needs.release-context.outputs.gem-name }}"'
    expect(run_commands(package_test)).to include(artifact_install)
    expect(run_commands(package_test)).not_to include('gem install --no-document --local')
  end

  it 'publishes the verified artifact bytes without rebuilding or using a wildcard' do
    publish = release.fetch('jobs').fetch('publish')
    commands = run_commands(publish)

    expect(publish.fetch('needs')).to include('package-test', 'release-context')
    expect(steps(publish)).to include(
      a_hash_including('uses' => a_string_starting_with('actions/download-artifact@'))
    )
    expect(commands).to include('sha256sum --check')
    expect(commands).to match(/gem push .+GEM_NAME/)
    expect(commands).not_to include('gem build')
    expect(commands).not_to match(/gem push .+\*/)
  end

  it 'publishes only the gem because GitHub Release creation cannot close the existing-tag race' do
    publish = release.fetch('jobs').fetch('publish')
    commands = run_commands(publish)

    expect(publish.dig('permissions', 'contents')).to eq('read')
    expect(commands.scan('script/verify-release-tag').length).to eq(1)
    expect(commands.index('script/verify-release-tag')).to be < commands.index('gem push')
    release_actions = steps(publish).select do |step|
      step.fetch('uses', '').include?('action-gh-release') || step.fetch('run', '').match?(/gh release/)
    end
    expect(release_actions).to be_empty
  end

  it 'scopes latest-pending replacement to validated publish candidates by tag' do
    jobs = release.fetch('jobs')
    publish = jobs.fetch('publish')

    expect(release).not_to have_key('concurrency')
    expect(publish.fetch('concurrency')).to eq(
      'group' => 'release-${{ needs.release-context.outputs.tag }}',
      'cancel-in-progress' => false
    )
    expect(publish.fetch('if')).to eq("needs.release-context.outputs.should-release == 'true'")
    expect(jobs.except('publish').values).to all(satisfy { |job| !job.key?('concurrency') })

    context_gate = jobs.fetch('release-context').fetch('if')
    expect(context_gate).to include("workflow_run.conclusion == 'success'")
    expect(context_gate).to include("workflow_run.event == 'push'")
    expect(context_gate).to include('workflow_run.head_repository.full_name == github.repository')
  end

  it 'models latest-pending replacement as a fail-closed tag contract' do
    publish = release.fetch('jobs').fetch('publish')
    sha_a = 'a' * 40
    sha_b = 'b' * 40
    running = ReleaseWorkflowSpec::Candidate.new(tag: 'v2.0.0', sha: sha_a, artifact_sha256: 'artifact-a')
    same_sha = ReleaseWorkflowSpec::Candidate.new(tag: 'v2.0.0', sha: sha_a, artifact_sha256: 'artifact-a')
    moved_tag = ReleaseWorkflowSpec::Candidate.new(tag: 'v2.0.0', sha: sha_b, artifact_sha256: 'artifact-b')
    unrelated = ReleaseWorkflowSpec::Candidate.new(tag: 'v2.0.1', sha: sha_b, artifact_sha256: 'artifact-c')

    expect(concurrency_group_for(running)).not_to eq(concurrency_group_for(unrelated))
    expect(concurrency_group_for(running)).to eq(concurrency_group_for(moved_tag))

    equivalent = latest_pending_transition(running: running, pending: running, incoming: same_sha)
    expect(equivalent).to include(running: running, pending: same_sha, replaced: running)
    expect(equivalent.fetch(:replaced).artifact_sha256).to eq(equivalent.fetch(:pending).artifact_sha256)

    moved = latest_pending_transition(running: running, pending: same_sha, incoming: moved_tag)
    expect(moved).to include(running: running, pending: moved_tag, replaced: same_sha)
    expect(pre_push_verifier_allows?(moved.fetch(:replaced), current_remote_tag_sha: sha_b)).to be(false)
    expect(pre_push_verifier_allows?(moved.fetch(:pending), current_remote_tag_sha: sha_b)).to be(true)

    expect(publish.dig('concurrency', 'cancel-in-progress')).to be(false)
    expect(moved.fetch(:running)).to equal(running)
    expect(pre_push_verifier_allows?(running, current_remote_tag_sha: sha_b)).to be(false)
    push_command = steps(publish).find { |step| step.fetch('run', '').include?('gem push') }.fetch('run')
    expect(push_command.index('script/verify-release-tag')).to be < push_command.index('gem push')
  end
end
