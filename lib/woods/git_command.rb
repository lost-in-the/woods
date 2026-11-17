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
  # Spawn every command with {CHILD_ENV} ahead of the argv. Woods reads
  # checkouts a developer is working in, and a `git status` that refreshes
  # stat data writes the index back under `.git/index.lock`, failing the
  # developer's own `git checkout` while it holds the lock. The environment
  # form, unlike `--no-optional-locks`, is ignored by Git before 2.15 rather
  # than failing the command; there the lock avoidance does not apply.
  # `git diff` refreshes the index regardless.
  module GitCommand
    # Environment variable naming the explicitly selected git directory.
    OVERRIDE_KEY = 'WOODS_GIT_DIR'

    # Child environment that skips the optional index write a read can make.
    CHILD_ENV = { 'GIT_OPTIONAL_LOCKS' => '0' }.freeze

    module_function

    # @param root [String, Pathname] repository root the command runs against
    # @param args [Array<String>] git arguments, global options included
    # @param env [Hash] environment source (overridable in specs)
    # @return [Array<String>] full argv for `Open3`
    def argv(root, *args, env: ENV)
      root = root.to_s
      override = env[OVERRIDE_KEY]
      return ['git', '-C', root, *args] if override.nil? || override.empty?

      ['git', '--git-dir', override, '--work-tree', root, '-C', root, *args]
    end
  end
end
