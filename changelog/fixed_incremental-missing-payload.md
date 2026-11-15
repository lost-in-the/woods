- Incremental extraction and targeted refresh no longer publish from a baseline they cannot read. When
  `generation.json` names a payload directory that is missing, or one that holds no `dependency_graph.json`, or
  names no payload while the output root holds no `dependency_graph.json`, the run refuses with
  `Woods::ExtractionError` before writing anything and names the directory. A graph held in memory by a reused
  extractor no longer stands in for a published generation's missing graph file, including a baseline that
  disappears while the run seeds it. Earlier writers started from an
  empty or stale graph and published a generation without the units and edges the run did not touch. Run a full
  `woods:extract` to rebuild the index; a full extraction now also recovers from an empty payload pointer, which
  it used to copy into itself until a filesystem call failed.
