- Spec fixture repositories turn off git's background maintenance, auto gc
  and fsmonitor, and the release-state snapshot tolerates a lock file git
  removes mid-copy. `FileUtils.cp_r` of a fresh repository raced
  `.git/objects/maintenance.lock` into `Errno::ENOENT` in CI.
