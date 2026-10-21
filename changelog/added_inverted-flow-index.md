- Publish optional `flows/by_unit.json` with typed unit-to-entry-point membership
  for precomputed flows, maintained across incremental replacement and deletion.
  Older flow generations reconstruct the inverse from retained flow documents
  on the next flow delta.
