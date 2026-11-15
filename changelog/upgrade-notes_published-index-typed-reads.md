- `Woods::PublishedIndex#unit(identifier, type:)` refuses a unit it cannot trust.
  A symlinked type directory or unit file, or a unit body naming another identifier, raises `IOError`.
  An indexed identifier whose unit file is missing raises `Errno::ENOENT`, a `SystemCallError`, not `IOError`.
  A unit file that will not parse raises `JSON::ParserError`.
  The untyped `#unit(identifier)` reads through the identifier map without these checks.
  It returns a unit file reached through a symlink, or a body naming another identifier, as it finds them,
  and raises `Errno::ENOENT` or `JSON::ParserError` unchanged; pass `type:` for the checked read.
  `#units` returns index entries without opening unit files, so it raises only where it reads a unit body:
  an entry with no usable `type` in a directory that holds several types (`graphql/`, `rails_source/`, `routes/`).
  In 2.1 such a unit was served, or silently left out.
  `Woods::PublishedIndex` also raises `CorruptPointerError` for a `generation.json` that exists but is unreadable,
  malformed, or names no valid generation.
  A RuboCop cop, gate script or other reader that should survive a damaged index rescues `IOError`,
  `SystemCallError`, `JSON::ParserError` and `Woods::PublishedIndex::CorruptPointerError`.
  A full `woods:extract` replaces a generation with damaged unit files.
  It does not repair a corrupt `generation.json`: every writer refuses one and asks you to restore it.
  Restore it to name a generation that was published.
  Every retained `payloads/gen-<n>` was, except possibly the newest one.
  A run that moved its payload into place and then failed to write the pointer leaves that newest `gen-<n>` behind
  unpublished, and reports `Could not publish generation for <index> (...); the previous generation remains active`.
  If you cannot rule that out, name the second newest, for example `{"number":3,"payload":"payloads/gen-3"}` when
  the newest is `payloads/gen-4`, then run `woods:extract`; its publication replaces the leftover directory.
