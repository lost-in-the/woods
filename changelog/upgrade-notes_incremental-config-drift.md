- `woods:incremental` and `woods:refresh` refuse with `Woods::ExtractionConfigChanged` after an extraction setting
  changes, and ask for one full `woods:extract`.
  An index written by 2.1 records no settings, so this check only logs a warning for it.
  The source-reference cache check still refuses that index, as the cache-format upgrade note describes.
