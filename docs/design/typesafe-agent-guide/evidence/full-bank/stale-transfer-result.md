# Conditional additional transfer mechanism

Confirmed in a new disposable copy of synthetic candidate `f9a470ec` at source commit `65ef6c0a87a95990f2f41250d699de20240b14df`. The planted rollback-atomicity control label remains unchanged.

The public service accepts Active Record wallet instances. This probe materializes both transfer snapshots before the first call commits, then invokes the service twice for 10 credits each. That is one admissible read/commit ordering when separate callers hand the service overlapping stale snapshots. The test does not start concurrent threads, establish how an unspecified application caller loads models, or claim that reloading alone solves every concurrent schedule.

| Shared wallet | Initial balances | Stale snapshots after both transfers | Fresh loads before each transfer |
| --- | --- | --- | --- |
| Recipient | Senders 100, 100; recipient 0 | 90, 90, 10: total 190, losing 10 credits | 90, 90, 20: total 200 |
| Sender | Sender 100; recipients 0, 0 | 90, 10, 10: total 110, losing a debit | 80, 10, 10: total 100 |

Both service calls complete in each scenario. `ReviewWallet` has only `id`, `balance`, and `limit` columns. Optimistic locking is disabled. The service uses its supplied instances' balances and unconditional per-ID updates; it does not reload or lock them. Captured SQL and persisted state support the observed overwrite.

Runtime: Rails 8.0.5.1, Ruby 3.3.1, SQLite. `stdout.json` records source hashes, loading order, per-call and final balances, locking state, and SQL. `run.json` records the exact Docker command, image ID, script hash, and unchanged frozen source/database evidence. The executed script is copied beside these receipts. `first-run/` retains the initial run before the locking-status field was renamed; scenario logic is unchanged.

No production fix, GitHub issue, new inference call, or original fixture/capture mutation was made. This is an additional verified conditional mechanism on a synthetic control, not a retroactive relabeling or a Woods runtime bug.
