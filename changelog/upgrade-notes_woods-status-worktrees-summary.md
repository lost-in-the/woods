- Only if you ran a 2.2 prerelease: `woods_status`'s `worktrees` section is now a summary object rather than an
  array of per-checkout entries. Woods 2.1 had no `worktrees` section.
  A client that read `root`, `state`, `generation`, `git_branch`, `git_sha` or `watch` from each entry passes
  `worktrees: "list"` to get the previous array unchanged.
