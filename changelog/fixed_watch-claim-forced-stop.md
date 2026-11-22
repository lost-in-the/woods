- A managed watcher stopped in the middle of an extraction no longer leaves its extraction lock or its claim behind.
  It could not finish its shutdown inside the launcher's 10 s shutdown timeout, so its guardian killed it before it
  released `extraction.lock` and `watch_claim.json`. A replacement container then parked with
  `owner_on_other_host` until a manual `woods-watch --recover-claim`, and once the claim was cleared its watcher
  still reported `contended` for the lock's 600 s stale window, because a lock from another host is judged by age
  alone. The launcher now retires both, lock first, so a successor that finds no claim is not then held by the dead
  watcher's lock; each step runs even when the other fails. It retires `extraction.lock` through the lock's own
  guarded capture-then-check (new `PipelineLock#retire_gone_holder`), only when the lock records this host and the
  pid that attempt reported, that pid is gone and its process group is gone; a lock a successor wrote meanwhile is
  put back, and a lock naming another host or pid stays however old. It retires the claim under the claim
  coordination lock, only when the version 2 claim was recorded on this host by that pid, that watcher's process
  group is gone (on Linux, unreaped zombies count as gone), the lease lock is free and the claim names it, and the
  claim did not change before the removal. Any other claim, including one from another host, stays where it is,
  and neither the claim sidecars nor the lock's guard file are touched. `docs/WATCH_DAEMON.md` now states the stop
  budget (13.5 s for the launcher, 17 s for Puma's stop hook) and the outer stop grace a container supervisor needs;
  Compose's default 10 s is shorter.
