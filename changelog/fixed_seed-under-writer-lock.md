- `rake woods:seed` seeds again instead of always running a full extraction.
  The task holds the target index's writer lock, and the seed's incremental run in `<output>.seed-<pid>` was
  refused for writing a directory that lock does not cover, so every seed fell back and the task still exited 0.
  The staging run now publishes under its own directory's writer lock.
  A fallback prints `Not seeded, ran a full extraction instead: <reason>`, with no absolute host path in the reason.
