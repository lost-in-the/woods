- The Console MCP server is deprecated and will be removed in Woods 3.0 (#1098). Existing setups keep working through
  2.x, but the Console gets no new features. Vulnerabilities are still fixed under `SECURITY.md`, and hardening is
  fixed in public. Starting it through `woods:console`, `exe/woods-console`, `Console::Server.build_embedded` or the
  mounted Rack endpoint, or setting `console_mcp_enabled = true`, prints one deprecation line per process on stderr,
  never on the stdio protocol channel. The `woods-console-mcp` launcher prints nothing itself; the server it starts
  prints the line. The Console guide opens with a deprecation notice and says what to use instead. The README, the
  documentation index, `SECURITY.md`, the install template and the `woods-setup` and `woods-mcp-config` skills no
  longer offer the Console for a new setup.
