- The advice for an unreadable `generation.json` no longer says to restore it to the newest retained `payloads/gen-<n>`.
  A writer moves its stage into place before it writes the marker, so a retained directory may never have published.
  Once the marker's number has gone backward, a writer can also replace a directory an older marker names.
  The writer refusal and the watcher now share one message.
  Restore the marker only from a complete backup of the marker and the payload directory it names.
  Otherwise keep the old output directory as it is, and extract and validate into a fresh one.
  `docs/TROUBLESHOOTING.md` gives the marker's shape and the reason.
