- `path` and `dependencies`/`dependents` with `explain: true` say how Woods knows each edge: `reflected` (Rails
  reported the relationship), `verified` (source text resolved against the running application), `static` (a
  source-text match nothing checked) or `unknown`. A `path` answer names its weakest hop in one `Evidence:` line and
  marks only the hops weaker than `reflected`; each explained edge gains an `evidence` attribute, classified by the
  type of the edge's own source unit. The class is read from a catalog in the gem (`Woods::EdgeEvidence`) keyed by
  source unit type and `via`, so extraction output, the graph file and `graph_sha` are unchanged and an existing
  index needs no re-extraction. A pair two mechanisms produce takes the weaker class and reads `at least`. No
  class means the code path executes.
