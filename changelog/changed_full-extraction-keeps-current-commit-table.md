- A normal `woods:extract` no longer forces a git history walk for `git_commits.json`.
  Every run, full or incremental, keeps the published table when it still records the same HEAD, indexed paths,
  window start, bounds and history rewrites (`GitCommitTable.current?`), and otherwise rebuilds the whole table.
  The table now records `history_rewrites`, a digest of the replace refs and grafts the walk honours, only in a
  repository that has them, so adding, changing or removing one rebuilds the table; when that state cannot be read,
  the run always walks.
  An unreadable table is rebuilt.
  A clean extraction (`woods:clean` first, or a fresh output directory) forces the walk.
