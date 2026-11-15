- The test bundle now takes Puma below 8.1 by default, and the hosted Puma 8 rows hold at 8.0.x (`~> 8.0.0`).
  `WOODS_PUMA_REQ` accepts a comma-separated requirement.
  Puma 8.1 waits for every child of a cluster master before it runs `after_stopped` hooks (puma/puma#4001).
  The Woods plugin stops its watcher in that hook, so a cluster stop through the control app or Ctrl-C never returns.
  The product behaviour on Puma 8.1 is not fixed: it is documented as a known limit in `docs/WATCH_DAEMON.md`
  and `docs/TROUBLESHOOTING.md`.
