# frozen_string_literal: true

require 'date'
require 'open3'

require_relative 'changelog'
require_relative 'notes'
require_relative 'version_state'

module Woods
  module Release
    # Performs the two version-state transitions on a checkout.
    #
    # `prepare` builds a release commit: it bumps VERSION, folds the changelog
    # into a dated heading, and restates the `release-state` fences. `reopen`
    # moves a released tree back to the next `.alpha`. Neither commits, tags,
    # pushes, or publishes anything: the reviewed pull request and the dispatch
    # workflow stay the only path to RubyGems.
    class Preparer
      # Raised when the working tree has changes the transition would bury.
      class DirtyWorkingTree < Error; end

      # Raised when VERSION cannot be read from lib/woods/version.rb.
      class UnreadableVersion < Error; end

      VERSION_PATH = 'lib/woods/version.rb'
      CHANGELOG_PATH = 'CHANGELOG.md'
      VERSION_ASSIGNMENT = /^(?<indent>\s*)VERSION = '(?<version>[^']+)'$/
      REPOSITORY = 'lost-in-the/woods'

      # The outcome of a transition, including the commands the maintainer runs next.
      Result = Struct.new(:previous, :target, :changed_paths, :report, keyword_init: true)

      class << self
        # Builds a release commit for `version` in the working tree at `root`.
        #
        # @return [Result]
        def prepare(root:, version:, date: Date.today)
          target = VersionState.parse(version)
          previous = current_state(root)
          VersionState.validate_prepare!(previous, target)
          assert_clean!(root)

          changed = [write_version(root, target), fold_changelog(root, target, date)]
          changed.concat(Notes.apply!(root: root, version: target.to_s))
          Result.new(previous: previous, target: target, changed_paths: changed.uniq.sort,
                     report: prepare_report(previous, target, changed))
        end

        # Reopens development at the next `.alpha` after a final release.
        #
        # @return [Result]
        def reopen(root:, version:)
          target = VersionState.parse(version)
          previous = current_state(root)
          VersionState.validate_reopen!(previous, target)
          assert_clean!(root)

          changed = [write_version(root, target)]
          changed.concat(Notes.apply!(root: root, version: target.to_s))
          Result.new(previous: previous, target: target, changed_paths: changed.uniq.sort,
                     report: reopen_report(previous, target, changed))
        end

        # @return [VersionState] the state the checkout is currently in
        def current_state(root)
          source = File.read(File.join(root, VERSION_PATH), encoding: Encoding::UTF_8)
          match = VERSION_ASSIGNMENT.match(source)
          raise UnreadableVersion, "#{VERSION_PATH} has no literal VERSION assignment" unless match

          VersionState.parse(match[:version])
        end

        private

        def assert_clean!(root)
          output, status = Open3.capture2e('git', 'status', '--porcelain', chdir: root)
          raise DirtyWorkingTree, "git status failed in #{root}: #{output.strip}" unless status.success?
          return if output.strip.empty?

          raise DirtyWorkingTree,
                "the working tree has uncommitted changes; commit or discard them first:\n#{output.rstrip}"
        end

        def write_version(root, target)
          path = File.join(root, VERSION_PATH)
          source = File.read(path, encoding: Encoding::UTF_8)
          File.write(path, source.sub(VERSION_ASSIGNMENT) { "#{Regexp.last_match(:indent)}VERSION = '#{target}'" })
          VERSION_PATH
        end

        def fold_changelog(root, target, date)
          path = File.join(root, CHANGELOG_PATH)
          source = File.read(path, encoding: Encoding::UTF_8)
          File.write(path, Changelog.fold(source, version: target.to_s, date: date))
          CHANGELOG_PATH
        end

        def prepare_report(previous, target, changed)
          <<~REPORT
            Prepared #{target} (from #{previous}).

            #{changed_summary(changed)}

            Nothing has been committed, tagged, or published. Review the diff, then:

              bin/rspec spec/release_v2 && bin/rake release_v2:verify_surface_inventory
              git add -A && git commit -m "chore(release): #{target}"

            Open a pull request. The release commit lands on main through review like
            any other change. After it merges, tag the merge commit and dispatch:

              git tag v#{target} <merge-sha> && git push origin v#{target}
              gh api --method POST repos/#{REPOSITORY}/dispatches \\
                -f event_type=release \\
                -F 'client_payload[tag]=v#{target}' \\
                -F 'client_payload[ci_run_id]=<green CI run id on the tagged SHA>'

            The workflow publishes the bytes CI tested. Never run `gem push` from a laptop.
            #{final_reopen_hint(target)}
          REPORT
        end

        def final_reopen_hint(target)
          return '' unless target.final?

          "\nOnce v#{target} is published, reopen development:\n\n  " \
            "bin/rake \"release:reopen[<next version>.alpha]\"\n"
        end

        def reopen_report(previous, target, changed)
          <<~REPORT
            Reopened development at #{target} (from the #{previous} release).

            #{changed_summary(changed)}

            Nothing has been committed. Review the diff, then commit and open a pull request:

              git add -A && git commit -m "chore(release): reopen development at #{target}"
          REPORT
        end

        def changed_summary(changed)
          return 'No files changed.' if changed.empty?

          "Changed:\n#{changed.uniq.sort.map { |path| "  #{path}" }.join("\n")}"
        end
      end
    end
  end
end
