# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'release validation' do
  let(:validator) { File.expand_path('../../script/validate-release', __dir__) }
  let(:tag_verifier) { File.expand_path('../../script/verify-release-tag', __dir__) }

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
