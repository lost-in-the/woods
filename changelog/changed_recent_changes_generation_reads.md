- Cache recent-change summaries per immutable generation and selected type bucket,
  avoiding repeated unit reads while retaining per-request reads for flat indexes.
