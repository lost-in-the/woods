- A full extraction that cannot open a new payload directory now raises `Woods::ExtractionError` and leaves the
  published generation unchanged.
  In 2.1 it warned and wrote the index flat into the output root, which is not atomic.
  A `woods:extract` or `Woods.extract!` caller that relied on the flat fallback should fix what stops the payload
  directory from opening, or set `WOODS_ALLOW_FLAT_FALLBACK=1`, which restores the fallback with a warning.
