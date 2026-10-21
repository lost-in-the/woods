- Normalize `event_paths` entries such as `./lib`, `lib//events` and `.`, so an incremental run
  re-runs events for the same roots a full extraction scans.
