# frozen_string_literal: true

require 'open3'

module Woods
  # Resolves git provenance (branch + commit SHA) for the extracted codebase,
  # correctly handling linked git worktrees where +.git+ is a *file* containing a
  # +gitdir:+ pointer rather than a directory.
  #
  # The reported failure (#137): in a worktree, +.git+ points at a real git
  # directory that may be an absolute host path. When extraction runs somewhere
  # that path cannot be resolved — e.g. inside a container where the host path
  # is not mounted — plain +git rev-parse+ fails silently and the manifest used
  # to fall back to a baked-in +GIT_BRANCH+ / +GIT_SHA+ build arg, reporting a
  # *stale, misleading* branch.
  #
  # Resolution precedence (never emit a misleading value):
  #
  # 1. Robust git resolution via +git -C <root> rev-parse+ — independent of the
  #    process working directory, and resolving a worktree's +.git+-file pointer
  #    when the pointed-to git directory is reachable. A worktree's branch is also
  #    read directly from the linked +HEAD+ file as a secondary path.
  # 2. When the +git+ binary works but cannot resolve the ref (e.g. a worktree
  #    whose real git directory is not mounted into this container), emit
  #    {UNKNOWN}. A working git that cannot determine the ref must not be papered
  #    over with a baked-in env var — that is exactly the stale value #137 is
  #    about.
  # 3. Only when git is entirely unavailable (no binary, or the directory is not a
  #    repository reachable by git) do +GIT_BRANCH+ / +GIT_SHA+ env vars apply, if
  #    set — the legitimate "no git in this environment, trust my build args"
  #    case. Otherwise the value is {UNKNOWN}.
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

      # Worktree safety net: read the branch straight from the linked HEAD file
      # when it is locally reachable but rev-parse came up empty.
      from_head = worktree_head_branch
      return from_head if present?(from_head)

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
      out, status = Open3.capture2('git', '-C', @root, 'rev-parse', *args)
      status.success? ? out.strip : ''
    rescue StandardError
      ''
    end

    # Decide what to emit when git resolution produced nothing.
    #
    # A working git binary that simply could not resolve the ref yields {UNKNOWN}
    # (never a baked env var — that is the stale-fallback bug). Env vars only
    # apply when git is entirely unavailable.
    def fallback(env_key)
      return UNKNOWN if git_binary_available?

      value = @env[env_key]
      present?(value) ? value : UNKNOWN
    end

    # True when the +git+ command itself can run, independent of any repository.
    def git_binary_available?
      _out, status = Open3.capture2('git', '--version')
      status.success?
    rescue StandardError
      false
    end

    # Parse +<root>/.git+ when it is a *file* (linked worktree) and read the
    # branch from the worktree git directory's +HEAD+ when that directory is
    # reachable. Returns nil for detached HEAD, an unreachable pointer, or any
    # parse failure.
    #
    # @return [String, nil]
    def worktree_head_branch
      dot_git = File.join(@root, '.git')
      return nil unless File.file?(dot_git)

      gitdir = parse_gitdir_pointer(dot_git)
      return nil unless gitdir && File.directory?(gitdir)

      head_path = File.join(gitdir, 'HEAD')
      return nil unless File.file?(head_path)

      ref = File.read(head_path).strip
      return nil unless ref.start_with?('ref:')

      ref.sub(%r{\Aref:\s*refs/heads/}, '')
    rescue StandardError
      nil
    end

    # Extract and absolutize the +gitdir:+ pointer from a worktree +.git+ file.
    # The pointer may be relative (resolved against +@root+) or absolute.
    #
    # @return [String, nil]
    def parse_gitdir_pointer(dot_git)
      pointer = File.read(dot_git)[/\Agitdir:\s*(.+?)\s*\z/m, 1]
      return nil unless pointer

      File.absolute_path(pointer.strip, @root)
    rescue StandardError
      nil
    end
  end
end
