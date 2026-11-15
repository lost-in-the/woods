- `incremental_blast_radius_depth` now defaults to `:structural` instead of `nil`.
  An incremental run follows inheritance, include and extend edges to any depth and every other edge one hop,
  so it re-derives fewer units than the unbounded closure 2.1 used.
  A host whose class hierarchy the graph does not record as inheritance edges can keep the previous behaviour with
  `config.incremental_blast_radius_depth = nil`.
  No re-extraction is needed.
