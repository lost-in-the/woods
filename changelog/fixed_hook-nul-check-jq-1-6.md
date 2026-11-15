- The plugin edit hook queues refreshes again on jq 1.6 (Debian 12, Ubuntu 22.04). Its NUL check used
  `contains("\u0000")`, which jq 1.6 answers `true` for every string, so every root and path was rejected and no
  refresh was queued. The check now uses `index`, which answers correctly on jq 1.6 and 1.7.
