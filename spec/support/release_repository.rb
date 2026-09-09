# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

# Builds a throwaway git repository holding copies of exactly the files the
# release flow rewrites, so `release:prepare` and the release-state fences can be
# exercised end to end without mutating this checkout.
module ReleaseRepositoryHelper
  SOURCE_ROOT = File.expand_path('../..', __dir__)
  RELEASE_FILES = %w[
    lib/woods/version.rb
    CHANGELOG.md
    README.md
    CONTRIBUTING.md
    docs/UPGRADING_TO_2.md
  ].freeze

  def with_release_repository(version: '2.0.0.alpha', changelog: nil, commit: true)
    Dir.mktmpdir('woods-release-repository') do |root|
      RELEASE_FILES.each do |path|
        FileUtils.mkdir_p(File.join(root, File.dirname(path)))
        FileUtils.cp(File.join(SOURCE_ROOT, path), File.join(root, path))
      end
      write_release_version(root, version)
      File.write(File.join(root, 'CHANGELOG.md'), changelog) if changelog
      commit_release_repository(root) if commit

      yield root
    end
  end

  def write_release_version(root, version)
    File.write(File.join(root, 'lib/woods/version.rb'), <<~RUBY)
      # frozen_string_literal: true

      module Woods
        VERSION = '#{version}'
      end
    RUBY
  end

  def read_release_version(root)
    File.read(File.join(root, 'lib/woods/version.rb'))[/VERSION = '([^']+)'/, 1]
  end

  def release_file(root, path)
    File.read(File.join(root, path), encoding: Encoding::UTF_8)
  end

  def release_git(root, *args)
    output, status = Open3.capture2e('git', *args, chdir: root)
    raise output unless status.success?

    output.strip
  end

  def commit_release_repository(root)
    release_git(root, 'init', '-b', 'main')
    release_git(root, 'config', 'user.email', 'release-test@example.invalid')
    release_git(root, 'config', 'user.name', 'Release Test')
    release_git(root, 'config', 'commit.gpgsign', 'false')
    release_git(root, 'add', '.')
    release_git(root, 'commit', '-m', 'release fixture')
  end
end

RSpec.configure do |config|
  config.include ReleaseRepositoryHelper
end
