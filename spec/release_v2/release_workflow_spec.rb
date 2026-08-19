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

  it 'builds one strict artifact and stores it with its SHA-256' do
    jobs = release.fetch('jobs')
    all_commands = jobs.values.map { |job| run_commands(job) }.join("\n")
    build_steps = steps(jobs.fetch('build'))

    expect(all_commands.scan('gem build').length).to eq(1)
    expect(run_commands(jobs.fetch('build'))).to include('gem build --strict')
    expect(run_commands(jobs.fetch('build'))).to include('sha256sum')
    expect(build_steps).to include(a_hash_including('uses' => a_string_starting_with('actions/upload-artifact@')))
  end

  it 'tests the uploaded artifact on the Ruby floor and latest lanes before publishing' do
    jobs = release.fetch('jobs')
    package_test = jobs.fetch('package-test')

    expect(package_test.fetch('needs')).to include('build')
    expect(package_test.dig('strategy', 'matrix', 'include')).to include(
      a_hash_including('ruby' => '3.0'),
      a_hash_including('ruby' => '4.0')
    )
    expect(steps(package_test)).to include(
      a_hash_including('uses' => a_string_starting_with('actions/download-artifact@'))
    )
    expect(run_commands(package_test)).to include('spec/integration/packaged_gem_spec.rb')
    artifact_install = 'gem install --no-document "dist/${{ needs.build.outputs.gem-name }}"'
    expect(run_commands(package_test)).to include(artifact_install)
    expect(run_commands(package_test)).not_to include('gem install --no-document --local')
  end

  it 'publishes the verified artifact bytes without rebuilding or using a wildcard' do
    publish = release.fetch('jobs').fetch('publish')
    commands = run_commands(publish)

    expect(publish.fetch('needs')).to include('build', 'package-test', 'release-context')
    expect(steps(publish)).to include(
      a_hash_including('uses' => a_string_starting_with('actions/download-artifact@'))
    )
    expect(commands).to include('sha256sum --check')
    expect(commands).to match(/gem push .+GEM_NAME/)
    expect(commands).not_to include('gem build')
    expect(commands).not_to match(/gem push .+\*/)
  end
end
