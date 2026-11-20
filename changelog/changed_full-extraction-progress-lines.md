- A full extraction now logs a progress line before each step after the request flows (`Writing dependency graph...`,
  `Writing skipped files report...`, `Building git commit table...`, `Writing manifest...`,
  `Publishing generation...`), and two between deduplication and dependents (`Annotating units...`,
  `Rebuilding dependency graph...`).
  The commit table's `git log -U0` walk could take seconds with no line naming it, so its time was read as part of
  the flows step.
  With `WOODS_PROFILE=1` the three steps that had no timing line now have one: `source accounting`,
  `flow withdrawal` (when `precompute_flows` is off) and `summary`.
