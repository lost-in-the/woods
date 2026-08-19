# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

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

  it 'serializes releases and revalidates the current remote tag before both publication actions' do
    publish = release.fetch('jobs').fetch('publish')
    commands = run_commands(publish)

    expect(release.fetch('concurrency')).to eq('group' => 'release', 'cancel-in-progress' => false)
    expect(commands.scan('script/verify-release-tag').length).to eq(2)
    expect(commands.index('script/verify-release-tag')).to be < commands.index('gem push')
    release_step_index = steps(publish).index do |step|
      step.fetch('uses', '').start_with?('softprops/action-gh-release@')
    end
    prior_step = steps(publish).fetch(release_step_index - 1)
    expect(prior_step.fetch('run')).to include('script/verify-release-tag')
  end
end
