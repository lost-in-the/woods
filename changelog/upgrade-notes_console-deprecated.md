- **Console MCP deprecation:** with `console_mcp_enabled = true`, every Rails process that loads the initializer
  prints one `[woods] DEPRECATED:` line on stderr, as does each Console start.
  Nothing else changes in 2.x.
  Plan to move off the Console before Woods 3.0.
  Use the Index Server for structural questions, and `bin/rails runner` or a focused spec for a runtime observation.
  For live data, use an agent owned by the application, with its own limited permissions.
  See `docs/CONSOLE_MCP_SETUP.md`.
