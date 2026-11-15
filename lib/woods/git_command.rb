# frozen_string_literal: true

module Woods
  # The one place a Woods git command line is built.
  #
  # Every git call Woods makes is rooted at the extracted application rather
  # than at the process working directory, so extraction launched from another
  # checkout never reports that checkout's history.
  #
  # `WOODS_GIT_DIR` wins when set and selects HEAD exactly as `--git-dir`
  # does. For a container over a linked worktree, select its private directory
  # within the complete mounted Git layout (shared objects, refs and worktrees).
  # Selecting the shared root instead selects the primary checkout's HEAD.
  # A same-path mount that resolves the worktree's .git pointer needs no override.
  #
  # Three call sites use this, and the documentation promises all three:
  # per-unit enrichment (`Extractor`), manifest provenance (`GitProvenance`),
  # and the `woods:incremental` diff range (`lib/tasks/woods.rake`).
  #
  # Every command also carries `--no-optional-locks`. Woods reads checkouts a
  # developer is working in, and a `git status` that refreshes stat data
  # writes the index back under `.git/index.lock`, failing the developer's
  # own `git checkout` while it holds the lock. `git diff` does not honour the
  # option: its index refresh still runs.
  module GitCommand
    # Environment variable naming the explicitly selected git directory.
    OVERRIDE_KEY = 'WOODS_GIT_DIR'

    # Global option that skips the optional index write a read can make.
    NO_OPTIONAL_LOCKS = '--no-optional-locks'

    module_function

    # @param root [String, Pathname] repository root the command runs against
    # @param args [Array<String>] git arguments, global options included
    # @param env [Hash] environment source (overridable in specs)
    # @return [Array<String>] full argv for `Open3`
    def argv(root, *args, env: ENV)
      root = root.to_s
      override = env[OVERRIDE_KEY]
      return ['git', NO_OPTIONAL_LOCKS, '-C', root, *args] if override.nil? || override.empty?

      ['git', NO_OPTIONAL_LOCKS, '--git-dir', override, '--work-tree', root, '-C', root, *args]
    end
  end
end
