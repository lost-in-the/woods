- Add `Woods::PublishedIndex#flow_entry_points(identifier, type:)` and `#flow_document(entry_point)`,
  which read `flows/by_unit.json` and indexed flow documents from the reader's pinned generation through
  the bounded no-follow artifact reader. Absent flow artifacts return `nil`; malformed, mismatched or
  symlinked ones raise `Woods::PublishedIndex::CorruptArtifactError`.
