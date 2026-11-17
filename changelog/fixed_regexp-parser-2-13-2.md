- Woods excludes `regexp_parser` 2.13.2, so a fresh install no longer fails when an MCP server defines a tool.
  That release made `Regexp::Syntax::Base.implements` private,
  and `json_schemer`, which the `mcp` SDK requires, raises `NoMethodError` while loading.
