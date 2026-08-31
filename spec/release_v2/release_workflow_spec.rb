# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'open3'
require 'tmpdir'
require 'yaml'

RSpec.describe 'release workflow contract' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:release_path) { File.join(root, '.github/workflows/release.yml') }
  let(:ci) { YAML.safe_load_file(File.join(root, '.github/workflows/ci.yml'), aliases: true) }
  let(:release) { YAML.safe_load_file(release_path, aliases: true) }
  let(:release_source) { File.read(release_path) }
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

  def checkout_steps(job)
    steps(job).select { |step| step.fetch('uses', '').start_with?('actions/checkout@') }
  end

  it 'keeps full incremental-equivalence depth on representative PR rows and every candidate build' do
    rails_job = ci.fetch('jobs').fetch('rails-matrix')
    rows = rails_job.dig('strategy', 'matrix', 'include')
    harness = steps(rails_job).find { |step| step['name'] == 'Run incremental equivalence harness' }
    full_rows = rows.select do |row|
      row['pr_diff_ops'] == '60' && row['pr_diff_seeds'] == '1,2,3'
    end
    smoke_rows = rows - full_rows

    expect(rows.length).to eq(9)
    expect(full_rows.map { |row| [row['ruby'], row['rails']] }).to contain_exactly(
      %w[3.0 6.0],
      %w[3.3 7.2],
      %w[3.4 8.1]
    )
    expect(smoke_rows).to all(include('pr_diff_ops' => '8', 'pr_diff_seeds' => '1'))
    expect(harness.fetch('env')).to eq(
      'WOODS_DIFF_OPS' => "${{ github.event_name == 'pull_request' && matrix.pr_diff_ops || '60' }}",
      'WOODS_DIFF_SEEDS' => "${{ github.event_name == 'pull_request' && matrix.pr_diff_seeds || '1,2,3' }}"
    )
  end

  it 'accepts only an explicit release repository dispatch without concurrency' do
    ci_trigger = ci.fetch('on') { ci.fetch(true) }
    dispatch = release_trigger['repository_dispatch']

    expect(ci_trigger.dig('push', 'tags')).to contain_exactly('v*')
    expect(release_trigger.keys).to contain_exactly('repository_dispatch')
    expect(dispatch.fetch('types')).to contain_exactly('release')
    expect(release_source).not_to include('workflow_dispatch:')
    expect(release_source).to include('gh api --method POST repos/lost-in-the/woods/dispatches')
    expect(release_source).to include('client_payload[tag]')
    expect(release_source).to include('client_payload[ci_run_id]')
    expect(release).not_to have_key('concurrency')
    expect(release.fetch('jobs').values).to all(satisfy { |job| !job.key?('concurrency') })
  end

  it 'checks out only the trusted default-branch SHA before all release-context validation' do
    context = release.fetch('jobs').fetch('release-context')
    context_steps = steps(context)
    tooling_checkout = context_steps.find { |step| step['name'] == 'Check out trusted default-branch SHA' }
    run_validation = context_steps.find { |step| step.fetch('run', '').include?('script/validate-release-run') }
    release_validation = context_steps.find do |step|
      step.fetch('run', '').lines.any? { |line| line.strip == 'script/validate-release --trusted-checkout' }
    end

    expect(context).not_to have_key('if')
    expect(context.fetch('permissions')).to eq('actions' => 'read', 'contents' => 'read')
    expect(checkout_steps(context)).to contain_exactly(tooling_checkout)
    expect(context_steps.index(tooling_checkout)).to eq(0)
    expect(tooling_checkout.dig('with', 'ref')).to eq('${{ github.sha }}')
    expect(context_steps.index(tooling_checkout)).to be < context_steps.index(run_validation)
    expect(context_steps.index(run_validation)).to be < context_steps.index(release_validation)
    expect(run_validation.fetch('env')).to include(
      'CI_RUN_ID' => '${{ github.event.client_payload.ci_run_id }}',
      'RELEASE_TAG' => '${{ github.event.client_payload.tag }}',
      'GITHUB_REPOSITORY' => '${{ github.repository }}'
    )
    expect(release_validation.fetch('env')).to include(
      'RELEASE_SHA' => '${{ steps.run.outputs.release-sha }}',
      'RELEASE_TAG' => '${{ steps.run.outputs.tag }}',
      'RELEASE_TRUSTED_SHA' => '${{ github.sha }}'
    )
    expect(run_commands(context)).not_to include('ruby -Ilib -rwoods/version')
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

  it 'downloads only the validated repository-dispatch CI artifact identified by run ID and SHA' do
    jobs = release.fetch('jobs')
    context = jobs.fetch('release-context')

    expect(context.fetch('outputs')).to include(
      'release-sha' => '${{ steps.run.outputs.release-sha }}',
      'ci-run-id' => '${{ steps.run.outputs.ci-run-id }}',
      'artifact-name' => '${{ steps.run.outputs.artifact-name }}',
      'artifact-id' => '${{ steps.run.outputs.artifact-id }}',
      'artifact-digest' => '${{ steps.run.outputs.artifact-digest }}'
    )

    %w[package-test publish].each do |job_name|
      job = jobs.fetch(job_name)
      downloads = download_steps(job)
      expect(downloads.length).to eq(1), job_name
      inputs = downloads.fetch(0).fetch('with')
      expect(inputs).not_to have_key('name')
      expect(inputs.fetch('artifact-ids')).to eq('${{ needs.release-context.outputs.artifact-id }}')
      expect(inputs.fetch('run-id')).to eq('${{ needs.release-context.outputs.ci-run-id }}')
      expect(inputs.fetch('github-token')).to eq('${{ github.token }}')
      expect(inputs.fetch('repository')).to eq('${{ github.repository }}')
      expect(run_commands(job)).to include('test -n "${ARTIFACT_DIGEST}"')
    end
  end

  it 'confines candidate checkout and execution to a secret-free read-only package job' do
    jobs = release.fetch('jobs')
    package_test = jobs.fetch('package-test')
    candidate_checkout = checkout_steps(package_test).fetch(0)

    expect(package_test.fetch('needs')).to eq('release-context')
    expect(package_test.fetch('name')).to eq('Candidate package tests (secret-free, read-only)')
    expect(package_test.fetch('permissions')).to eq('actions' => 'read', 'contents' => 'read')
    expect(package_test).not_to have_key('environment')
    expect(package_test.to_s).not_to include('secrets.')
    expect(package_test.to_s).not_to include('id-token')
    expect(package_test.fetch('permissions').values).not_to include('write')
    expect(checkout_steps(package_test).length).to eq(1)
    expect(candidate_checkout.dig('with', 'ref')).to eq('${{ needs.release-context.outputs.release-sha }}')
    expect(candidate_checkout.dig('with', 'persist-credentials')).to be(false)
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
    tooling_checkout = checkout_steps(publish).fetch(0)
    push = steps(publish).find { |step| step.fetch('run', '').include?('gem push') }

    expect(publish.fetch('environment')).to eq('release')
    expect(publish.dig('permissions', 'contents')).to eq('read')
    expect(checkout_steps(publish).length).to eq(1)
    expect(tooling_checkout.dig('with', 'ref')).to eq('${{ github.sha }}')
    expect(tooling_checkout.dig('with', 'ref')).not_to eq('${{ needs.release-context.outputs.release-sha }}')
    expect(push.fetch('env')).to include('RELEASE_TRUSTED_SHA' => '${{ github.sha }}')
    expect(commands.scan('script/verify-release-tag --trusted-checkout').length).to eq(1)
    expect(commands.index('script/verify-release-tag --trusted-checkout')).to be < commands.index('gem push')
    release_actions = steps(publish).select do |step|
      step.fetch('uses', '').include?('action-gh-release') || step.fetch('run', '').match?(/gh release/)
    end
    expect(release_actions).to be_empty
  end
end
