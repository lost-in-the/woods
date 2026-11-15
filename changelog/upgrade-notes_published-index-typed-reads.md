- `Woods::PublishedIndex#unit(identifier, type:)` raises `IOError` on a unit it cannot trust:
  a symlinked type directory or unit file, a unit body naming another identifier, or an indexed identifier whose
  unit file is missing.
  `#units` returns index entries without opening unit files, so it raises only where it reads a unit body:
  an entry with no usable `type` in a directory that holds several types (`graphql/`, `rails_source/`, `routes/`).
  In 2.1 such a unit was served, or silently left out.
  `Woods::PublishedIndex` also raises `CorruptPointerError` for a `generation.json` that exists but is unreadable,
  malformed, or names no valid generation.
  A RuboCop cop, gate script or other reader that should survive a damaged index rescues these errors.
  A full `woods:extract` replaces a generation with damaged unit files.
  It does not repair a corrupt `generation.json`: every writer refuses one and asks you to restore it.
  Write it to name the newest retained payload, for example `{"number":3,"payload":"payloads/gen-3"}`
  for `payloads/gen-3`, then run `woods:extract`.
