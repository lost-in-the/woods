- A managed watcher whose index is bind-mounted into a container can now be recovered after that container is
  removed without a clean stop. Claims bound ownership to the lease file's device and inode as the writing process
  saw them. On a bind mount those numbers are not stable across mount sessions or between a container and the
  host, so `woods-watch --recover-claim` from a later session refused with `owner lease inode changed`.
  New claims record `lease_version: 2` and a random `lease_id` written inside the lease file; recovery and
  same-host takeover compare it through the descriptor that holds the lock, so a deleted and recreated lease is
  still refused. A version 1 claim is recovered with its exact token and a free lease, whatever device and inode
  it recorded. A launcher parked behind another host's claim now reports `owner_on_other_host` and prints the
  owner host, pid and the exact recovery command, and every recovery refusal names its next step. No message
  prints the token; refusals that need manual recovery name the "Manual claim recovery"
  section of `docs/WATCH_DAEMON.md`. A replacement container still never takes over another host's claim on its own.
