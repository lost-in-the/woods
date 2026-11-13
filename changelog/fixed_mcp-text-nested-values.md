- MCP tool text in the Markdown, Claude and plain formats no longer prints Ruby `inspect` output.
  A nested value in `lookup` metadata, a tool result with no renderer of its own, graph analysis stats
  and a search's applied scope read `(key: value)` and `[a, b]` (`null` for a missing value inside them),
  not `{"verb" => "GET"}` or `["a", "b"]`.
