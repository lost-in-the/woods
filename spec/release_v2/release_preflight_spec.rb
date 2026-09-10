# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/release/preflight'

# The three live prerequisites `release:prepare` cannot verify without a
# network call, added after the beta1 dispatch failed on each of them one at
# a time (see CONTRIBUTING.md "When a dispatch fails"). Every check here is
# advisory: `Preflight.run` and `.report` never raise, so a prepare in an
# offline worktree still completes.
RSpec.describe Woods::Release::Preflight do
  let(:root) { File.expand_path('../..', __dir__) }

  def write_fake_gh(directory, response:, exit_status: 0)
    fake_bin = File.join(directory, 'bin')
    FileUtils.mkdir_p(fake_bin)
    gh = File.join(fake_bin, 'gh')
    File.write(gh, <<~RUBY)
      #!/usr/bin/env ruby
      if #{exit_status} != 0
        warn 'gh: authentication required'
        exit #{exit_status}
      end
      print #{response.inspect}
    RUBY
    FileUtils.chmod(0o755, gh)
    fake_bin
  end

  describe '.check_environment_protection' do
    def result_for(environment:)
      Dir.mktmpdir('woods-preflight-env') do |dir|
        fake_bin = write_fake_gh(dir, response: JSON.generate(environment))
        described_class.check_environment_protection(env: { 'PATH' => "#{fake_bin}:#{ENV.fetch('PATH')}" })
      end
    end

    it 'passes when the live release environment has a protection rule and no admin bypass' do
      result = result_for(environment: { 'protection_rules' => [{ 'type' => 'required_reviewers' }],
                                         'can_admins_bypass' => false })

      expect(result.status).to eq(:ok)
    end

    it 'warns when the live release environment has no protection rules' do
      result = result_for(environment: { 'protection_rules' => [], 'can_admins_bypass' => false })

      expect(result.status).to eq(:warning)
      expect(result.message).to include('no protection rules configured')
    end

    it 'warns when the live release environment allows administrator bypass' do
      result = result_for(environment: { 'protection_rules' => [{ 'type' => 'required_reviewers' }],
                                         'can_admins_bypass' => true })

      expect(result.status).to eq(:warning)
      expect(result.message).to include('allows administrators to bypass')
    end

    it 'skips, never fails, when gh is not on PATH' do
      Dir.mktmpdir('woods-preflight-no-gh') do |empty_dir|
        result = described_class.check_environment_protection(env: { 'PATH' => empty_dir })

        expect(result.status).to eq(:skipped)
        expect(result.message).to match(/gh/)
      end
    end

    it 'skips, never fails, when gh fails (offline or unauthenticated)' do
      Dir.mktmpdir('woods-preflight-gh-fails') do |dir|
        fake_bin = write_fake_gh(dir, response: '', exit_status: 1)
        result = described_class.check_environment_protection(env: { 'PATH' => "#{fake_bin}:#{ENV.fetch('PATH')}" })

        expect(result.status).to eq(:skipped)
      end
    end
  end

  describe '.check_required_ci_jobs' do
    it 'passes against the real validator and ci.yml' do
      result = described_class.check_required_ci_jobs(root)

      expect(result.status).to eq(:ok)
    end

    it 'warns when a required job id no longer exists in ci.yml' do
      Dir.mktmpdir('woods-preflight-missing-job') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'script'))
        FileUtils.mkdir_p(File.join(dir, '.github/workflows'))
        File.write(File.join(dir, 'script/validate-release-run'), <<~RUBY)
          REQUIRED_CI_JOBS = {
            'test' => 'Unit specs (Ruby '
          }.freeze
        RUBY
        File.write(File.join(dir, '.github/workflows/ci.yml'), <<~YAML)
          jobs:
            other:
              name: Something else
        YAML

        result = described_class.check_required_ci_jobs(dir)

        expect(result.status).to eq(:warning)
        expect(result.message).to include('test')
      end
    end

    it 'warns when a required job name prefix no longer matches the renamed ci.yml job' do
      Dir.mktmpdir('woods-preflight-renamed-job') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'script'))
        FileUtils.mkdir_p(File.join(dir, '.github/workflows'))
        File.write(File.join(dir, 'script/validate-release-run'), <<~RUBY)
          REQUIRED_CI_JOBS = {
            'live-backends' => 'Live backends (pgvector + Qdrant + Solid Cache)'
          }.freeze
        RUBY
        File.write(File.join(dir, '.github/workflows/ci.yml'), <<~YAML)
          jobs:
            live-backends:
              name: Live backends (pgvector + Qdrant + Solid Cache + Redis)
        YAML

        result = described_class.check_required_ci_jobs(dir)

        expect(result.status).to eq(:warning)
        expect(result.message).to include('live-backends')
      end
    end
  end

  describe '.check_merge_multiple' do
    it 'passes against the real release.yml' do
      result = described_class.check_merge_multiple(root)

      expect(result.status).to eq(:ok)
    end

    it 'warns when a download-artifact step is missing merge-multiple: true' do
      Dir.mktmpdir('woods-preflight-workflow') do |dir|
        FileUtils.mkdir_p(File.join(dir, '.github/workflows'))
        File.write(File.join(dir, '.github/workflows/release.yml'), <<~YAML)
          jobs:
            package-test:
              steps:
                - uses: actions/download-artifact@v4
                  with:
                    artifact-ids: x
        YAML

        result = described_class.check_merge_multiple(dir)

        expect(result.status).to eq(:warning)
        expect(result.message).to include('package-test')
      end
    end
  end

  describe '.report' do
    it 'names every check without raising, whether or not gh is reachable here' do
      report = described_class.report(root: root)

      expect(report).to include(
        'release environment protection', 'REQUIRED_CI_JOBS matches ci.yml', 'download-artifact merge-multiple'
      )
    end
  end
end
