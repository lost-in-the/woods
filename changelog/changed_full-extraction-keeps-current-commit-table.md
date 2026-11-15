- A full extraction now keeps the published `git_commits.json` when the table still records the same HEAD, indexed
  paths, window start and bounds (`GitCommitTable.current?`), as incremental runs already did, instead of walking the
  history and the `-U0` patches again to write the same bytes.
  Any changed input still rebuilds the whole table; an unreadable table is rebuilt; `woods:clean` before a full run
  forces the walk.
