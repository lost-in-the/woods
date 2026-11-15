- The test bundle and the hosted Puma 8 rows exclude Puma 8.1.0 (`!= 8.1.0`).
  With the Woods plugin and workers above 0, a Puma 8.1.0 cluster stop through the control app or Ctrl-C never returns.
  Puma fixed it upstream in 8.1.1 (puma/puma#4135).
  `WOODS_PUMA_REQ` accepts a comma-separated requirement.
  `docs/WATCH_DAEMON.md` and `docs/TROUBLESHOOTING.md` list 8.1.0 as a known limit.
