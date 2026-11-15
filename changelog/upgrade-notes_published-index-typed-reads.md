- `Woods::PublishedIndex#unit(identifier, type:)` and `#units` raise `IOError` on a unit they cannot trust:
  a symlinked type directory or unit file, a unit body naming another identifier, or an indexed identifier whose
  unit file is missing.
  In 2.1 such a unit was served, or silently left out.
  `Woods::PublishedIndex` also raises `CorruptPointerError` for a `generation.json` that parses but names no valid
  generation.
  A RuboCop cop, gate script or other reader that should survive a damaged index rescues these errors;
  a full `woods:extract` replaces the damaged generation.
