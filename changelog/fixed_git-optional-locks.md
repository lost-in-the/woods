- Woods' git reads no longer take the checkout's index lock.
  `woods_status`, extraction, worktree routing and seeding, and the build-identity check now pass `--no-optional-locks`,
  so a `git status` that refreshes stat data no longer rewrites `.git/index` under `index.lock`.
  A developer's `git checkout` could fail on that lock while a client polled `woods_status`.
  `git diff` (the `woods:incremental` range) does not honour the option and still refreshes the index.
