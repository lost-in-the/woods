- Incremental extraction and targeted refresh no longer publish from a baseline they cannot read. When
  `generation.json` names a payload directory that is missing, or one that holds no `dependency_graph.json`, the run
  refuses with `Woods::ExtractionError` before writing anything and names the directory. Earlier writers seeded the
  run from the flat output root, started from an empty or stale graph, and published a generation without the units
  and edges the run did not touch. Run a full `woods:extract` to rebuild the index.
