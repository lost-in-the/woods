- The Index MCP server has an always-on `path` tool that answers "how does unit A reach unit B" with the shortest
  chain of published edges from `from` to `to`.
  Each hop names both units, their types and every `via` label on that edge.
  - **Arguments:** `from` and `to`, `from_type` and `to_type` for an identifier registered under several unit
    types, `max_depth` (1 to 20, default 6), `max_nodes` (1 to 10000, default 10000), `direction` (`forward`,
    or `either` to also try `to` reaching `from`) and the worktree `root`.
  - **Search:** breadth-first over the pinned generation's forward edges, with neighbours visited in sorted
    order, so the same shortest path is returned whatever order the units were extracted in.
    A path never passes through a documentation unit. Nothing is computed at extraction.
  - **No path** is a successful answer.
    It says whether the search was exhaustive or stopped by `max_depth` or `max_nodes`, so a bounded search is
    never read as "not connected".
  - **Refusals:** an unknown end is `not_found` with near matches, and an identifier registered under several
    types with none named is `ambiguous_identity` with the candidate types.
  - `Woods::DependencyGraph#shortest_path` (`Woods::ShortestPath`) is the search.
  - The Index Server defines 32 schemas; 16 register in the packaged default.
