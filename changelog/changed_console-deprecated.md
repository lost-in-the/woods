- The Console MCP server is deprecated and will be removed in Woods 3.0 (#1098).
  Existing setups keep working through 2.x, but the Console gets no new features.
  Vulnerabilities are still fixed under `SECURITY.md`, and hardening is fixed in public.
  Each Console start prints one deprecation line per process on stderr, never on the stdio protocol channel.
  That covers `woods:console`, `exe/woods-console`, `Console::Server.build_embedded` and the mounted Rack endpoint.
  Setting `console_mcp_enabled = true` prints the same line.
  The `woods-console-mcp` launcher prints nothing itself; the server it starts prints the line.
  The Console guide opens with a deprecation notice and says what to use instead.
  The README, the documentation index, `SECURITY.md`, the install template and two plugin skills stop offering it.
