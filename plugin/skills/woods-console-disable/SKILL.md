---
name: woods-console-disable
description: Turn off the deprecated Woods Console MCP server in a Rails app and verify it; keeps the Index Server.
---

# Turn the Woods Console off

The Console Server is deprecated in Woods 2.2.0 and removed in Woods 3.0.
Existing setups keep working; new setups should not enable it.
Use this skill when a user wants the Console off, ahead of 3.0 or after a security notice.

What to use instead:

- **Structural questions** (associations, callbacks, dependents, routes, flows): the Index Server.
- **A runtime observation in development**: `bin/rails runner` or a focused spec.
- **Live data**: an agent owned by the application, with its own limited permissions.

## Rules

- **Ask before every edit.** Show the file, the line and the change first; edit only after the user agrees.
- **Never delete a file.** Edit lines out, or move a file aside (`console.yml` to `console.yml.disabled`).
- **Never print a token value.** Search with `grep -o` for key names only, and never open a file that holds a token.
  For such a file, name the file and line number and ask the user to remove the line.
- **Leave the Index Server alone.** Keep every `woods-mcp`, `woods-mcp-start` and `woods-mcp-http` entry as it is.
- **Touch only Console lines.** Do not reformat a file, reorder keys or change unrelated settings.
- Files outside the repository (user-level client configuration, `~/.woods/`) need the user's explicit go-ahead.

## Preflight

```bash
bundle info woods
git status --short --branch
```

Record the installed version: 1.6, 2.1, or 2.2 and later.
A few steps differ by line; see "Version differences".
Note whether Rails runs on the host or through Docker Compose; run the Rails commands below where Rails runs.
Record uncommitted changes, and do not edit over them without asking.

## 1. Find every place

Run these from the application root.
Each prints file names, line numbers and key names only.

```bash
# Switch and other Console options, and hand-written Console code
grep -rnoE "console_mcp_[a-z_]+|console_embedded_read_tools|Woods::Console::[A-Za-z]+" config lib app 2>/dev/null
# Initializer lines that assign a literal token: do not open these files
grep -rnE "console_mcp_token[[:space:]]*=[[:space:]]*['\"]" config 2>/dev/null | cut -d: -f1,2
# Processes and scripts that start the Console
grep -rnoE "woods:console|woods-console-mcp|exe/woods-console" \
  Procfile* bin script docker-compose*.y*ml compose*.y*ml .mcp.json 2>/dev/null
# Environment variables, in any tracked or untracked file
grep -rnoE "WOODS_CONSOLE_(MCP_TOKEN|CONFIG|UNSAFE_EVAL)|CODEBASE_CONSOLE_CONFIG" . \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tmp --exclude-dir=log 2>/dev/null
```

List the MCP client entries without printing secrets:

```bash
jq -r '.mcpServers // {} | to_entries[] |
  "\(.key)\t\(.value.command // .value.url // "")\t\((.value.args // []) | join(" ") | gsub("=[^ ]+"; "=<redacted>"))"' \
  .mcp.json
```

A Console entry runs `woods:console`, `woods-console-mcp` or `exe/woods-console`.
An HTTP Console entry has a URL ending in the Console path.
The default Console path is `/mcp/console`; a custom one is set by `console_mcp_path` in `config/application.rb`.
Entries can have any name (`woods-console`, `rails-console`, `codebase-console`), so match the command, not the name.

Ask the user which other clients they use.
For Claude Code user and local scopes, list servers with `claude mcp list`.
Remove one with `claude mcp remove <name> -s <scope>`.
Other clients keep their own files, for example `.cursor/mcp.json`, `.vscode/mcp.json` or a desktop app's settings.
Check outside the repository for `~/.woods/console.yml` and for `WOODS_CONSOLE_CONFIG` in the shell profile.

## 2. Show the plan and ask

Show one table before any edit:

| Place | File and line | Change |
|---|---|---|
| Switch | `config/initializers/woods.rb:NN` | Remove `config.console_mcp_enabled = true`, or set it to `false` |
| Other Console options | same file | Optional: remove the `console_*` lines; they are inert once the switch is off |
| Client entry | `.mcp.json` | Remove the `<name>` entry; keep the Index Server entry |
| Hand-written Rack mount | `config/application.rb:NN` | Remove the `Woods::Console::RackMiddleware` line |
| Token (`WOODS_CONSOLE_MCP_TOKEN`) | file and line only | The user removes it and its secret-store copy; drop the client's `Authorization` header |
| Launcher file | `~/.woods/console.yml` | Move aside to `console.yml.disabled` |
| Process | `Procfile.dev:NN`, Compose service | Remove the entry that runs `woods:console` or `woods-console-mcp` |

Then ask the user to approve the plan, or to pick the rows to apply.
Stop if they decline.

## 3. Make the edits

- Edit only the approved rows, one at a time.
- In JSON client files, remove only the Console entry and keep the rest of the file as it was.
- Keep the automatic Rails mount: with the switch off it passes every request through to the application.
- Leave Rails credentials, CI secrets and password managers to the user; say which entry to remove there.

## 4. Restart and verify

Restart the Rails processes and the MCP client: Woods reads the switch at boot, and clients read their entries at start.
Then run, where Rails runs:

```bash
bin/rails runner 'p Woods.configuration.console_mcp_enabled'   # expect false or nil
bin/rake woods:console < /dev/null; echo "exit=$?"              # expect the disabled line and exit=1
```

On Woods 2.2 and later the rake check prints these two lines, then `exit=1`:

```text
[woods] DEPRECATED: The Console MCP server is deprecated and will be removed in Woods 3.0. Existing setups keep working through 2.x; use the Index Server for structural questions (see docs/CONSOLE_MCP_SETUP.md).
Woods Console MCP is disabled. Set Woods.configuration.console_mcp_enabled = true to enable. See docs/CONSOLE_MCP_SETUP.md for the full security posture.
```

`exit=0` means the Console started and is still on: go back to step 1.
For an HTTP setup, send a request with no token and check its status:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/mcp/console
```

`401` means the Console is still mounted and on; with it off the request reaches the application (usually `404`).
Finally call `woods_status` through the client to confirm the Index Server still answers.

## Version differences

- **2.1:** same keys and steps; the rake check prints only the "disabled" line.
- **1.6:** there is no `console_mcp_http_enabled`.
  The automatic HTTP mount exists only while the switch is on at boot.
  A hand-written `Woods::Console::RackMiddleware` mount answers `410` with `woods_console_disabled`, meaning off.
  The `woods-console-mcp` launcher does not load the application's initializer and always reports "disabled".
  Use the rake check instead.
  Older 1.6 guides name `CODEBASE_CONSOLE_CONFIG`; 1.6.4 reads only `WOODS_CONSOLE_CONFIG`, so look for both.

## Handoff

Report each place found, what changed and what the user still has to do (secret stores, other machines).
Include the two check results and the `woods_status` call.
Point the user to the alternatives above for the questions they used the Console for.

Canonical guide: [Turning the Console off](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_MCP_SETUP.md#turning-the-console-off).
