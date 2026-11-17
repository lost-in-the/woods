- A child process forked inside a running watch daemon, for example by a host callback during start-up catch-up,
  no longer acts for the daemon.
  The child unwound the same run, so it published status under its own pid, wrote `watch_pending.json` and, with
  a claim lease, removed the daemon's claim; `woods:watch_status` then read the live daemon as stopped.
  The status record, the pending paths and the claim now belong to the process that started the run.
  In a child the daemon writes none of them and does not take the claim for its own.
- A child forked during `woods:seed`'s incremental run no longer finishes the seed.
  It used to promote the half-built `<output>.seed-<pid>` directory, fall back to a full extraction, or remove the
  directory, and the parent's seed then failed.
  The child now leaves the seed to the process that built it.
