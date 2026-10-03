- Bound regex backtracking in `EventExtractor`. The built-in Wisper publisher
  pattern no longer lets two whitespace runs split the same spaces, which was
  quadratic on Rubies without the 3.2+ match cache. On Ruby 3.2+, configured
  `event_patterns` carry a 1-second per-match limit; a pattern that exceeds it
  is logged and skipped for that file while the other patterns still run.
