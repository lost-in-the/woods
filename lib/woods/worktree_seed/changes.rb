# frozen_string_literal: true

require 'open3'
require 'pathname'
require_relative '../change_set'
require_relative '../git_command'
require_relative '../input_rules'
require_relative '../rake_helpers'
require_relative 'verification'

module Woods
  class WorktreeSeed
    # The paths an incremental run must be given to bring a seeded index up to a
    # worktree: everything that differs from the seed's commit, committed or
    # not, tracked or untracked, filtered by the rules `woods:incremental` uses.
    class Changes
      # @param root [Pathname] the worktree's application root
      # @param index [Pathname] the seeded index, for its declared source roots
      def initialize(root:, index:)
        @root = root
        @index = index
      end

      # @param sha [String] the commit the seed describes
      # @return [Array<String>] root-relative paths to re-extract
      # @raise [Unverifiable] when a diff cannot be taken, or a path needs a
      #   fresh Rails boot and so a full extraction
      def since(sha)
        diffed, failure = RakeHelpers.woods_changed_paths_for_range(sha, root: @root)
        raise Unverifiable, "cannot diff against the seed's commit (#{failure})" if failure

        paths = ChangeSet.new(paths: diffed + untracked, root: @root).relative_paths
                         .reject { |path| Pathname.new(path).absolute? }
        rules = InputRules.for_index(@index)
        paths = paths.reject { |path| rules.action(path) == :ignore }
        boot = paths.find { |path| rules.action(path) == :full }
        raise Unverifiable, "#{boot} changed and needs a fresh Rails boot" if boot

        paths
      end

      private

      def untracked
        out, _err, status = Open3.capture3(
          *GitCommand.argv(@root, '-c', 'core.quotePath=false', 'ls-files', '--others', '--exclude-standard', '-z')
        )
        raise Unverifiable, 'cannot list untracked files' unless status.success?

        out.dup.force_encoding(Encoding::UTF_8).split("\0")
      end
    end
  end
end
