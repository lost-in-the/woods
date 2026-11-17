- Woods' git reads no longer take the checkout's index lock.
  `woods_status`, extraction, worktree routing and seeding, and the build-identity check now run git with
  `GIT_OPTIONAL_LOCKS=0`, so a `git status` that refreshes stat data no longer rewrites `.git/index` under `index.lock`.
  A developer's `git checkout` could fail on that lock while a client polled `woods_status`.
  Git before 2.15 ignores the variable, so there the reads behave as before.
  `git diff` (the `woods:incremental` range) does not honour it and still refreshes the index.
