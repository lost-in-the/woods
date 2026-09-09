# frozen_string_literal: true

module Woods
  # The one place a Woods git command line is built.
  #
  # Every git call Woods makes is rooted at the extracted application rather
  # than at the process working directory, so extraction launched from another
  # checkout never reports that checkout's history.
  #
  # `WOODS_GIT_DIR` wins when set. It is the escape hatch for a container over
  # a linked worktree: `.git` there is a file naming an absolute host path that
  # may not be mounted, and git's own `GIT_DIR` is not enough, because a
  # worktree's private git directory reaches the shared object store through a
  # relative `commondir` pointer that resolves outside the mount, which
  # `GIT_COMMON_DIR` does not override (B-181, B-186).
  #
  # Three call sites use this, and the documentation promises all three:
  # per-unit enrichment (`Extractor`), manifest provenance (`GitProvenance`),
  # and the `woods:incremental` diff range (`lib/tasks/woods.rake`).
  module GitCommand
    # Environment variable naming the canonical git directory.
    OVERRIDE_KEY = 'WOODS_GIT_DIR'

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
