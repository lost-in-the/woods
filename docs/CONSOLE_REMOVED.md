# Console removed

Woods 2.2.0 removes the Console MCP server: `rake woods:console`, `exe/woods-console`, the `woods-console-mcp`
launcher, the `Woods::Console::RackMiddleware` endpoint at `/mcp/console`, and every `console_*` tool.
The Index Server, extraction and the published index are unchanged.

## Why

The Console ran live Active Record queries for an agent and filtered secrets out of the output.
That filtering cannot be made complete.
Keeping it safe is not viable, so Woods no longer ships it.

## Cleaning up after an upgrade

1. **MCP client entry.** Remove the Console entry from `.mcp.json` and from any user-level client configuration.
   It is the entry that runs `woods:console`, `woods-console-mcp` or `exe/woods-console`,
   or whose URL ends in `/mcp/console`.
   Keep the Index Server entry (`woods-mcp`, `woods-mcp-start` or `woods-mcp-http`).
2. **Rack mount.** Remove any `Woods::Console::RackMiddleware` line you added by hand.
3. **Token.** Remove `WOODS_CONSOLE_MCP_TOKEN` from the application environment and its secret store,
   and the `Authorization` header that carried it from the client entry.
   Unset `WOODS_CONSOLE_CONFIG` and `WOODS_CONSOLE_UNSAFE_EVAL`, and move `~/.woods/console.yml` aside.
4. **Settings.** Remove every `config.console_*` line from your Woods initializer, `config/application.rb`
   and `config/environments/`, and any reference to `Woods::DEFAULT_CONSOLE_REDACTED_COLUMNS` or
   `Woods::DEFAULT_CONSOLE_BLOCKED_TABLES` (both are now empty).
5. **Processes.** Remove any Compose service, Procfile line or script that runs `woods:console` or `woods-console-mcp`.

Until then, the old entry points stop with this line:

```text
The Woods Console MCP server was removed in Woods 2.2.0. See docs/CONSOLE_REMOVED.md for the cleanup steps.
```

- **At boot:** `console_mcp_enabled` or `console_embedded_read_tools` set to a true value raises
  `Woods::ConfigurationError` with that line.
  Every other `console_*` setting, and `false` or `nil` for those two, is accepted, ignored and reads as `nil`,
  so an initializer that only turned the Console off keeps booting.
- **When Rails builds its middleware:** a hand-written `Woods::Console::RackMiddleware` mount raises the same error.
- **On the command line:** `rake woods:console`, `exe/woods-console` and `woods-console-mcp` print the line on
  stderr and exit with status 1.

On the 1.6.x and 2.1.x lines the Console still exists and is unsupported.
To turn it off there, see [Console MCP Server](CONSOLE_MCP_SETUP.md).
