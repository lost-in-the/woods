- `DependencyGraph#unregister` now drops the graph's memoized serialization, PageRank, suffix index and
  structural view, as `register`, `remove` and `annotate` already did; before, a caller that unregistered a unit
  read `to_h`, `pagerank` and `structural_graph` as they were before the call. Every mutator now clears memos
  through one private method, and a spec checks each mutator against a graph that never built them.
