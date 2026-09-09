# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

# Builds a throwaway git repository holding a canned changelog and canned fenced
# documents, so `release:prepare` and the release-state fences can be exercised
# end to end without reading this checkout.
#
# The fixture is deliberately not a copy of the repository files. Copying them
# made every transition spec assume the checked-in tree was an alpha with a
# non-empty Unreleased section, so the release commit that moved the tree to a
# prerelease could not pass its own specs.
module ReleaseRepositoryHelper
  CHECKOUT_ROOT = File.expand_path('../..', __dir__)
  FIXTURE_ROOT = File.expand_path('../fixtures/release_repository', __dir__)
  RELEASE_FILES = %w[
    lib/woods/version.rb
    CHANGELOG.md
    README.md
    CONTRIBUTING.md
    docs/UPGRADING_TO_2.md
  ].freeze

  # @return [String] this checkout, for the invariant checks that read the tree
  #   the suite is running in rather than the fixture
  def release_checkout_root
    CHECKOUT_ROOT
  end

  def build_release_repository(root, version: '2.0.0.alpha', changelog: nil, commit: true)
    RELEASE_FILES.each do |path|
      FileUtils.mkdir_p(File.join(root, File.dirname(path)))
      FileUtils.cp(File.join(FIXTURE_ROOT, path), File.join(root, path))
    end
    write_release_version(root, version)
    File.write(File.join(root, 'CHANGELOG.md'), changelog) if changelog
    commit_release_repository(root) if commit
    root
  end

  def with_release_repository(version: '2.0.0.alpha', changelog: nil, commit: true)
    Dir.mktmpdir('woods-release-repository') do |root|
      yield build_release_repository(root, version: version, changelog: changelog, commit: commit)
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

  # Every file the release flow may write, by content, so a refused transition
  # can be shown to have touched nothing.
  def release_repository_digest(root)
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) && !path.include?("#{File::SEPARATOR}.git#{File::SEPARATOR}") }
       .sort.to_h { |path| [path.delete_prefix("#{root}#{File::SEPARATOR}"), File.binread(path)] }
  end

  def release_file(root, path)
    File.read(File.join(root, path), encoding: Encoding::UTF_8)
  end

  def release_git(root, *args)
    output, status = Open3.capture2e('git', *args, chdir: root)
    raise output unless status.success?

    output.strip
  end

  def commit_release_repository_changes(root, message: 'release step')
    release_git(root, 'add', '-A')
    release_git(root, 'commit', '-m', message)
  end

  def add_unreleased_entry(root, heading, entry)
    path = File.join(root, 'CHANGELOG.md')
    source = File.read(path, encoding: Encoding::UTF_8)
    File.write(path, source.sub("## [Unreleased]\n", "## [Unreleased]\n\n### #{heading}\n\n#{entry}\n"))
    commit_release_repository_changes(root, message: 'add an entry')
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
