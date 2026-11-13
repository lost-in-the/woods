- MCP tool text in the Markdown, Claude and plain formats no longer prints Ruby `inspect` output.
  A nested value in `lookup` metadata, a tool result with no renderer of its own, graph analysis stats
  and a search's applied scope read `(key: value)` and `[a, b]` (`null` for a missing value inside them),
  not `{"verb" => "GET"}` or `["a", "b"]`.
  A whole-unit `lookup` lists each dependency and dependent as `key: value` pairs, not a Ruby Hash.
  The plain format now separates them with `; `.
  It prints no key for a value that says nothing (nil, `""`, `[]`, `{}`, or a list or object of only
  those), at the top of its metadata or nested inside it, and no metadata heading when nothing is left.
  `false` and `0` are still printed.
