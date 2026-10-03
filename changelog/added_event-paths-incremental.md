- Incremental runs now re-run `EventExtractor` when a `.rb` file under any
  `config.event_paths` root changes, not only under `app/`. With
  `event_paths = %w[app lib]`, adding or removing a publisher in a `lib/` file
  no longer needs a full extraction. The source-capture rules fingerprint
  includes the configured roots. Changing the `event_paths` value itself still
  needs one full extraction.
