# frozen_string_literal: true

require 'date'
require 'open3'

require_relative 'changelog'
require_relative 'fragments'
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
    class Preparer # rubocop:disable Metrics/ClassLength
      # Raised when the working tree has changes the transition would bury.
      class DirtyWorkingTree < Error; end

      # Raised when VERSION cannot be read from lib/woods/version.rb.
      class UnreadableVersion < Error; end

      VERSION_PATH = 'lib/woods/version.rb'
      CHANGELOG_PATH = 'CHANGELOG.md'
      VERSION_ASSIGNMENT = /^(?<indent>\s*)VERSION = '(?<version>[^']+)'$/
      REPOSITORY = 'lost-in-the/woods'

      # The outcome of a transition, including the commands the maintainer runs
      # next. The report is rendered from `changed_paths` on demand.
      Result = Struct.new(:previous, :target, :changed_paths, :render, keyword_init: true) do
        def report
          render.call(changed_paths)
        end

        # Folds in a file the caller changed after the transition (the rake task
        # regenerates the surface inventory), so the report lists everything the
        # reviewer will see in the diff.
        def with_changed(paths)
          Result.new(previous: previous, target: target, render: render,
                     changed_paths: (changed_paths + Array(paths)).uniq.sort)
        end
      end

      class << self
        # Builds a release commit for `version` in the working tree at `root`.
        #
        # Every rewrite is computed before any of it is written. The changelog
        # fold and the fence rewrite both refuse for reasons only visible after
        # the version transition validates, and a refusal that had already
        # rewritten VERSION would leave a half-released tree behind.
        #
        # @return [Result]
        def prepare(root:, version:, date: Time.now.utc.to_date)
          target = VersionState.parse(version)
          previous = current_state(root)
          assert_maintenance_transition!(previous, target, :prepare)
          VersionState.validate_prepare!(previous, target)
          assert_clean!(root)

          fragments = Fragments.read(root)
          changelog = Changelog.fold(
            read(root, CHANGELOG_PATH), version: target.to_s, date: date, entries: fragments.values
          )
          rewrites = { VERSION_PATH => version_source(root, target), CHANGELOG_PATH => changelog }
          rewrites.merge!(Notes.rewrites(root: root, version: target.to_s, changelog: changelog))
          changed = write(root, rewrites)
          fragments.each_key { |path| File.unlink(File.join(root, path)) }
          result(previous, target, (changed + fragments.keys).sort) { |paths| prepare_report(previous, target, paths) }
        end

        # Reopens development at the next `.alpha` after a final release. The
        # changelog is already folded, so only VERSION and the fences move.
        #
        # @return [Result]
        def reopen(root:, version:)
          target = VersionState.parse(version)
          previous = current_state(root)
          assert_maintenance_transition!(previous, target, :reopen)
          VersionState.validate_reopen!(previous, target)
          assert_clean!(root)

          rewrites = { VERSION_PATH => version_source(root, target) }
          rewrites.merge!(Notes.rewrites(root: root, version: target.to_s))
          result(previous, target, write(root, rewrites)) { |changed| reopen_report(previous, target, changed) }
        end

        # @return [VersionState] the state the checkout is currently in
        def current_state(root)
          source = File.read(File.join(root, VERSION_PATH), encoding: Encoding::UTF_8)
          match = VERSION_ASSIGNMENT.match(source)
          raise UnreadableVersion, "#{VERSION_PATH} has no literal VERSION assignment" unless match

          VersionState.parse(match[:version])
        end

        private

        def assert_maintenance_transition!(previous, target, operation)
          expected = operation == :reopen ? %w[1.6.3 1.6.4.alpha] : %w[1.6.4.alpha 1.6.4]
          return if [previous.to_s, target.to_s] == expected

          raise VersionState::InvalidTransition,
                "the maintenance adapter only supports #{expected.join(' -> ')} for #{operation}"
        end

        def assert_clean!(root)
          output, status = Open3.capture2e('git', 'status', '--porcelain', chdir: root)
          raise DirtyWorkingTree, "git status failed in #{root}: #{output.strip}" unless status.success?
          return if output.strip.empty?

          raise DirtyWorkingTree,
                "the working tree has uncommitted changes; commit or discard them first:\n#{output.rstrip}"
        end

        def result(previous, target, changed, &render)
          Result.new(previous: previous, target: target, changed_paths: changed, render: render)
        end

        def read(root, path)
          File.read(File.join(root, path), encoding: Encoding::UTF_8)
        end

        # @return [Array<String>] the paths whose content actually moved
        def write(root, rewrites)
          rewrites.filter_map do |path, source|
            next if read(root, path) == source

            File.write(File.join(root, path), source)
            path
          end.sort
        end

        def version_source(root, target)
          read(root, VERSION_PATH)
            .sub(VERSION_ASSIGNMENT) { "#{Regexp.last_match(:indent)}VERSION = '#{target}'" }
        end

        def prepare_report(previous, target, changed)
          <<~REPORT
            Prepared #{target} (from #{previous}).

            #{changed_summary(changed)}

            Nothing has been committed, tagged, pushed, or published.
            Review the diff, run bin/rspec spec/release_legacy and the full CI/package checks,
            then open a pull request into the approved release/1.6.4 target.
            First land a reviewed trusted-main profile update pinning approved_sha to
            that exact maintenance merge SHA. The unpinned profile refuses publication.
            Only after the pin is reviewed and merged may the maintainer tag that SHA
            and request publication:

              git tag v#{target} <merge-sha> && git push origin v#{target}
              gh api --method POST repos/#{REPOSITORY}/dispatches \\
                -f event_type=release \\
                -F 'client_payload[tag]=v#{target}' \\
                -F 'client_payload[ci_run_id]=<green tag-push CI run id>'

            The trusted main workflow publishes the exact artifact CI tested.
            This one-off adapter does not authorize any other maintenance release.
          REPORT
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
