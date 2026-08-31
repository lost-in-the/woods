# frozen_string_literal: true

require 'open3'

module Woods
  # Resolves git provenance (branch + commit SHA) for the extracted codebase,
  # correctly handling linked git worktrees where +.git+ is a *file* containing a
  # +gitdir:+ pointer rather than a directory.
  #
  # The reported failure (#137): in a worktree, +.git+ points at a real git
  # directory that may be an absolute host path. When extraction runs somewhere
  # that path cannot be resolved — e.g. inside a container where the host path is
  # not mounted — plain +git rev-parse+ fails silently and the manifest used to
  # fall back to a baked-in +GIT_BRANCH+/+GIT_SHA+ build arg, reporting a stale,
  # misleading branch.
  #
  # Resolution precedence:
  #
  # 1. +git -C <root> rev-parse+ — independent of the process working directory,
  #    and resolves a worktree's +.git+-file pointer when the target git directory
  #    is reachable. This covers normal checkouts and reachable worktrees.
  # 2. If that fails, {fallback} decides:
  #    - A +.git+ entry exists at the root but git couldn't resolve the ref (an
  #      unmounted worktree gitdir, a corrupted repo): emit {UNKNOWN}. A working
  #      tree whose ref can't be determined must not be papered over with a
  #      possibly-stale build arg — that is the #137 bug.
  #    - No +.git+ at the root at all (a source tarball, or a Docker +COPY+ that
  #      excludes +.git+), or no +git+ binary: the +GIT_BRANCH+/+GIT_SHA+ env vars
  #      are the only provenance signal, so honor them if set, else {UNKNOWN}.
  #
  # @example
  #   provenance = Woods::GitProvenance.new(root: Rails.root)
  #   provenance.branch  # => "main" (or "unknown")
  #   provenance.sha     # => "a1b2c3..." (or "unknown")
  class GitProvenance
    # Sentinel emitted when provenance cannot be determined, in preference to a
    # stale or misleading fallback value.
    UNKNOWN = 'unknown'

    # @param root [String, Pathname] repository root (typically +Rails.root+)
    # @param env [Hash] environment source (default +ENV+; overridable in specs)
    def initialize(root:, env: ENV)
      @root = root.to_s
      @env = env
    end

    # @return [String] current branch name, or {UNKNOWN}
    def branch
      from_git = rev_parse('--abbrev-ref', 'HEAD')
      # 'HEAD' means detached — not a branch name.
      return from_git if present?(from_git) && from_git != 'HEAD'

      fallback('GIT_BRANCH')
    end

    # @return [String] current commit SHA, or {UNKNOWN}
    def sha
      from_git = rev_parse('HEAD')
      return from_git if present?(from_git)

      fallback('GIT_SHA')
    end

    # @return [Hash{Symbol => String}] +{ git_branch:, git_sha: }+ for the manifest
    def to_h
      { git_branch: branch, git_sha: sha }
    end

    private

    def present?(value)
      value && !value.empty?
    end

    # Run git rooted at +@root+ so the result is independent of the process
    # working directory and resolves a worktree's +.git+-file pointer when the
    # target git directory is reachable.
    #
    # @return [String] stripped output, or empty string on any failure
    def rev_parse(*args)
      out, _err, status = Open3.capture3('git', '-C', @root, 'rev-parse', *args)
      status.success? ? out.strip : ''
    rescue StandardError
      ''
    end

    # Decide what to emit when git resolution produced nothing. A baked +GIT_*+
    # env var is honored only when this checkout is not a git working tree (no
    # +.git+ at the root) or git is unavailable. When git is present AND a +.git+
    # exists but the ref couldn't be resolved (unmounted worktree gitdir), emit
    # {UNKNOWN} rather than a possibly-stale value (#137).
    def fallback(env_key)
      return UNKNOWN if git_available? && git_working_tree?

      value = @env[env_key]
      present?(value) ? value : UNKNOWN
    end

    # True when the +git+ command itself can run, independent of any repository.
    # Memoized — probed at most once per instance even though both +branch+ and
    # +sha+ may reach {fallback}.
    def git_available?
      return @git_available if defined?(@git_available)

      @git_available = begin
        _out, _err, status = Open3.capture3('git', '--version')
        status.success?
      rescue StandardError
        false
      end
    end

    # True when +<root>/.git+ exists — a directory for a normal checkout, or a
    # file for a linked worktree. Distinguishes "git couldn't resolve this
    # working tree" (emit UNKNOWN) from "there is no working tree here" (the
    # env-var build-arg path is legitimate).
    def git_working_tree?
      File.exist?(File.join(@root, '.git'))
    end
  end
end
