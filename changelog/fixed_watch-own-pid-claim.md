- A watcher restarted inside the same container now starts again after a crash. A restarted container keeps its
  hostname and reuses its pids, so the claim the killed watcher left could name the pid of the new watcher, which
  read as a live owner. The raw task then stood down and exited 0 on every start, and a managed launcher parked with
  `already_running`. A same-host claim naming the starting process's own pid is now stale unless a daemon in that
  process holds it, so a second daemon in one process is still refused. A raw `woods:watch` that stands down now
  prints one stderr line naming the claim's pid and host and the recovery step, instead of only `Watcher stopped.`.
