- Correct linked-worktree Git mount guidance and the runtime repair warning to
  select the worktree-specific HEAD within the complete shared Git layout.
  Regressions cover exact branch/SHA, feature-only history and incremental paths
  after relocation. Document the need for full extraction when current Git
  metadata is required after a commit that does not trigger the source watcher.
