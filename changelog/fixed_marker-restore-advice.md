- The advice for an unreadable `generation.json` no longer says to restore it to the newest retained `payloads/gen-<n>`.
  A writer moves its stage into place before it writes the marker.
  So after a failed publish, the newest directory never published.
  The writer refusal and the watcher now share one message.
  Name a generation known to have been published, or the second newest when unsure.
  Extract afresh when there is no evidence.
  `docs/TROUBLESHOOTING.md` gives the marker's shape.
