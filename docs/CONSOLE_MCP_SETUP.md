# Console MCP Server

> **Removed in Woods 2.2.0.** [Console removed](CONSOLE_REMOVED.md) says why and lists the cleanup steps.

This page is for applications still on Woods 2.1.x or 1.6.x.
The Console still exists there and is unsupported; turn it off if you enabled it.

## Turning the Console off

The `woods-console-disable` plugin skill finds these places, asks before each edit, and makes the edits it safely can.
Search first; `-o` prints file names, line numbers and key names, never values:

```bash
grep -rnoE "console_mcp_[a-z_]+|Woods::Console|woods:console|woods-console|WOODS_CONSOLE_[A-Z_]+" \
  --exclude-dir=credentials --exclude='*.key' config lib .mcp.json
```

Do not print `.env` files, `.mcp.json`, client configuration or `console.yml`: they can hold the token.
Where a step below touches such a line, find it by its line number and key name.

The skill decides what it may open by the kind of file, and a clean secret check never widens that.
It opens only Ruby configuration files, and not one the check flags.
It removes MCP client entries from plain JSON by key, and moves `console.yml` aside without opening it.
It gives you every other change as a manual step, the token always among them.

1. **Switch.** Remove `config.console_mcp_enabled = true` from `config/initializers/woods.rb`, or set it to `false`.
   Check `config/application.rb` and `config/environments/` too.
   With the switch off, every other `console_*` option is inert; you can remove those lines as well.
2. **MCP client entry.** In `.mcp.json`, and in any user-level client configuration, remove the Console entry.
   It is the entry that runs `woods:console`, `woods-console-mcp` or `exe/woods-console`.
   For HTTP, it is the entry whose URL is this application's Console endpoint, query aside:
   the same scheme, host and port, and exactly the Console path (default `/mcp/console`).
   An entry at that path on another host or port belongs to another application: keep it.
   A URL whose path only starts with it, such as `/mcp/console-metrics`, may be another server: confirm it first.
   Keep the Index Server entry (`woods-mcp`, `woods-mcp-start` or `woods-mcp-http`).
3. **Rack mount.** The automatic mount passes every request through to Rails once the switch is off.
   Remove any `Woods::Console::RackMiddleware` line you added by hand, and a custom `console_mcp_path`.
4. **Token and launcher file.** Remove `WOODS_CONSOLE_MCP_TOKEN` from the application environment and its secret store.
   Remove the `Authorization` header that carried it from the client entry.
   Unset `WOODS_CONSOLE_CONFIG`, and move `~/.woods/console.yml` aside if nothing else uses it.
5. **Processes.** Remove any Compose service, Procfile line or script that runs `woods:console` or `woods-console-mcp`.
   Restart the Rails processes, because Woods reads the switch at boot.
6. **Check.** `bin/rails runner 'p Woods.configuration.console_mcp_enabled'` prints `false` (or `nil`).
   `bin/rake woods:console < /dev/null; echo $?` prints these two lines and `1`:

   ```text
   [woods] DEPRECATED: The Console MCP server is deprecated and will be removed in Woods 3.0. Existing setups keep working through 2.x; use the Index Server for structural questions (see docs/CONSOLE_MCP_SETUP.md).
   Woods Console MCP is disabled. Set Woods.configuration.console_mcp_enabled = true to enable. See docs/CONSOLE_MCP_SETUP.md for the full security posture.
   ```

   An exit status of `0` means the Console started and is still on.
   Over HTTP, a request to the Console path no longer answers `401`; it reaches the application (usually `404`).

On Woods 2.1 the keys and steps are the same, and the check prints only the second line.
On Woods 1.6:

- `console_mcp_http_enabled` does not exist, and the automatic HTTP mount is added only while the switch is on at boot.
- A `Woods::Console::RackMiddleware` mounted by hand answers `410` with `woods_console_disabled` once the switch is off.
- The `woods-console-mcp` launcher always reports "disabled", because it does not load the application's initializer.
  Use the `bin/rake woods:console` check instead.
- Older 1.6 guides name `CODEBASE_CONSOLE_CONFIG`; 1.6.4 reads only `WOODS_CONSOLE_CONFIG`, so unset both.

The rest of this guide is for existing setups.

## The full guide

The full Console guide is in the documentation of each line:
[Woods 2.1.0](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/CONSOLE_MCP_SETUP.md) and
[Woods 1.6.4](https://github.com/lost-in-the/woods/blob/v1.6.4/docs/CONSOLE_MCP_SETUP.md).

