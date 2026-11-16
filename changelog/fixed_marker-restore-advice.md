- The advice for an unreadable `generation.json` no longer says to restore it to the newest retained `payloads/gen-<n>`.
  A writer moves its stage into place before it writes the marker, so a retained directory may never have published.
  The order of the retained directories is not evidence of publication either.
  The writer refusal and the watcher now share one message.
  Restore the marker only to a generation independently known to have been published, such as from a backup.
  Otherwise keep the old output directory as it is, and extract and validate into a fresh one.
  `docs/TROUBLESHOOTING.md` gives the marker's shape.
