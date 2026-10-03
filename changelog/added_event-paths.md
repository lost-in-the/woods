- Add `config.event_paths` (default `%w[app]`) to choose the directories
  `EventExtractor` scans, so an application whose event wrapper or listeners
  live in `lib/` can add `lib`. The setter validates a non-empty list of
  relative paths at assignment and raises `Woods::ConfigurationError`
  otherwise. Changing it needs a full extraction: incremental runs still
  re-run events only for changes under `app/`.
