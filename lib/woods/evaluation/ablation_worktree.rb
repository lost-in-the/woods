# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'shellwords'

module Woods
  module Evaluation
    # Sets up and tears down one disposable git worktree per ablation trial
    # (#280), checked out from a fixed baseline SHA so an on/off pair for
    # the same task starts from the identical commit. The trial never runs
    # in the caller's own working directory, and a reset failure aborts the
    # trial rather than being ignored.
    #
    # @example
    #   worktree = AblationWorktree.new(repo_root: '/app', baseline_sha: sha, executor: executor)
    #   error = worktree.trial('git checkout -- . && git clean -fdq') { |path| run_agent(path) }
    #   error # => nil on success, an error string otherwise (the block never ran)
    class AblationWorktree
      # @param repo_root [String] the repository the trial is checked out from
      # @param baseline_sha [String, nil] the commit every trial checks out
      # @param executor [#call] `call(command, chdir:)` returning `[stdout, stderr, success]`
      def initialize(repo_root:, baseline_sha:, executor:)
        @repo_root = repo_root
        @baseline_sha = baseline_sha
        @executor = executor
      end

      # @param reset_command [String, nil]
      # @yieldparam path [String] the checkout root, only when setup succeeded
      # @return [String, nil] an error message when the checkout or reset
      #   failed (the block never ran), else nil
      def trial(reset_command)
        parent = nil
        path = nil
        added = false

        parent = Dir.mktmpdir('woods-ablation-')
        path = File.join(parent, 'checkout')
        error = add_worktree(path)
        added = error.nil?
        error ||= reset(path, reset_command) if added && reset_command
        yield path if error.nil?
        error
      ensure
        teardown(path) if added
        FileUtils.remove_entry(parent, true) if parent
      end

      private

      def add_worktree(path)
        _out, err, ok = run_in_repo("git worktree add --detach #{Shellwords.escape(path)} #{@baseline_sha}")
        ok ? nil : "git worktree add failed: #{err.to_s.strip}"
      end

      def reset(path, reset_command)
        _out, err, ok = @executor.call(reset_command, chdir: path)
        ok ? nil : "reset failed: #{err.to_s.strip}"
      end

      def teardown(path)
        run_in_repo("git worktree remove --force #{Shellwords.escape(path)}")
      end

      def run_in_repo(command)
        @executor.call(command, chdir: @repo_root)
      end
    end
  end
end
