- **Console MCP removed:** an application that turns the Console on stops at boot with one line,
  `The Woods Console MCP server was removed in Woods 2.2.0. See docs/CONSOLE_REMOVED.md for the cleanup steps.`
  - **Raises:** `console_mcp_enabled` or `console_embedded_read_tools` set to a true value, and constructing
    `Woods::Console::RackMiddleware` (a hand-written mount).
  - **Accepted and ignored:** every other former `console_*` setting, and `false` or `nil` for those two,
    so an initializer that only turned the Console off keeps booting. Each reads back as `nil`.
    `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS` and `Woods::DEFAULT_CONSOLE_BLOCKED_TABLES` remain, empty.
  - **Exit 1 with the same line on stderr:** `rake woods:console`, `exe/woods-console` and `woods-console-mcp`.
  - **Clean up:** remove the Console MCP client entry, the Rack mount, `WOODS_CONSOLE_MCP_TOKEN` and the
    `console_*` settings, as `docs/CONSOLE_REMOVED.md` lists.
  - **Embedders:** `Woods::Console::CredentialScanner` is now `Woods::CredentialScanner`, without the
    credential-index layer the Console alone used.
