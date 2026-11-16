- On a git older than 2.31, which cannot run the history walk, extraction no longer fails each walk and reports
  `history_read_failed` in the Rails log only. It skips the walks and prints one line on the terminal naming the
  version found and the version needed, once per process (a resident watcher says it once), and the
  `git_enrichment` summary records the reason `git_too_old`. A failing git walk now names git's first stderr line
  in its warning.
