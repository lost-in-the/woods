# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'release validation' do
  let(:validator) { File.expand_path('../../script/validate-release', __dir__) }

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

  def build_repository(changelog: "## [2.0.0] - 2026-08-19\n")
    Dir.mktmpdir('woods-release-validator') do |repository|
      git('init', '-b', 'main', chdir: repository)
      git('config', 'user.email', 'release-test@example.invalid', chdir: repository)
      git('config', 'user.name', 'Release Test', chdir: repository)
      write_release_files(repository, changelog: changelog)
      git('add', '.', chdir: repository)
      git('commit', '-m', 'release candidate', chdir: repository)
      git('update-ref', 'refs/remotes/origin/main', 'HEAD', chdir: repository)
      git('tag', 'v2.0.0', chdir: repository)
      yield repository
    end
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
end
