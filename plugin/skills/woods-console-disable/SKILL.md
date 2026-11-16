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
- **Never print a value.** Inventory commands print names and locations only: file, line number, key name.
  Use only the commands below, which follow that rule.
  Do not print a file that can hold a secret, such as `.env`, `.mcp.json`, `console.yml` or a Compose file.
  Do not print the environment, a resolved Compose configuration or a configuration object.
- **Open a file only after the secret check passes for it.** For a file it flags, give the user the line and the change.
  The user makes that edit; the agent never reads the line.
- **Name keys, not values,** in the plan, the questions and the handoff.
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
# Switch, other Console options and hand-written Console code
grep -rnoE "console_mcp_[a-z_]+|console_embedded_read_tools|Woods::Console::[A-Za-z]+" config lib app 2>/dev/null
# Processes and scripts that start the Console
grep -rnoE "woods:console|woods-console-mcp|exe/woods-console" \
  Procfile* bin script docker-compose*.y*ml compose*.y*ml .mcp.json 2>/dev/null
# Console environment variable names, in any tracked or untracked file
grep -rnoE "WOODS_CONSOLE_(MCP_TOKEN|CONFIG|UNSAFE_EVAL)|CODEBASE_CONSOLE_CONFIG" . \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tmp --exclude-dir=log 2>/dev/null
# Whether the variables are set in this shell (run it where Rails runs, too)
[ -n "${WOODS_CONSOLE_MCP_TOKEN:-}" ] && echo "WOODS_CONSOLE_MCP_TOKEN is set"
[ -n "${WOODS_CONSOLE_CONFIG:-}" ] && echo "WOODS_CONSOLE_CONFIG is set"
[ -n "${WOODS_CONSOLE_UNSAFE_EVAL:-}" ] && echo "WOODS_CONSOLE_UNSAFE_EVAL is set"
```

List MCP client entries by name, kind and key names:

```bash
woods_mcp_entries() {
  jq -r --arg path "${CONSOLE_PATH:-/mcp/console}" '
    def kind: ((([.command // ""] + (.args // [])) | join(" ")) as $c
      | if ($c | test("woods:console|woods-console-mcp|exe/woods-console"))
           or ((.url // "") | index($path) != null) then "console"
        elif ($c | test("woods-mcp")) then "index" else "other" end);
    def rows($scope): to_entries[] | [$scope, .key, (.value | kind),
      "fields=" + (.value | keys | join(",")),
      "env=" + ((.value.env // {}) | keys | join(",")),
      "headers=" + ((.value.headers // {}) | keys | join(","))] | @tsv;
    ((.mcpServers // .servers // {}) | rows("top")),
    ((.projects // {}) | to_entries[] | .key as $p | (.value.mcpServers // {}) | rows("local " + $p))
  ' "$@"
}
woods_mcp_entries .mcp.json
```

A `console` row is the entry to remove; an `index` row is the Index Server and stays.
An `other` row with a URL may be the Index Server over HTTP; leave it too.
Set `CONSOLE_PATH` first if `console_mcp_path` in `config/application.rb` names a custom path.
Entries can have any name (`woods-console`, `rails-console`, `codebase-console`), so trust the kind, not the name.

Ask the user which other clients they use, and run `woods_mcp_entries` on each file they name.
Claude Code keeps user and local scopes in `~/.claude.json`; other clients use files such as `.vscode/mcp.json`.
Do not list servers with Claude Code's own list or get subcommands: they print commands, URLs and environment values.

Outside the repository, with the user's go-ahead:

```bash
# The launcher file: presence and key names only
if [ -f ~/.woods/console.yml ]; then
  ruby -ryaml -e 'puts "console.yml keys: #{(YAML.safe_load_file(ARGV[0]) || {}).keys.join(",")}"' ~/.woods/console.yml
fi
# Console variable names in shell profiles
grep -noE "WOODS_CONSOLE_[A-Z_]+|CODEBASE_CONSOLE_CONFIG" ~/.zshrc ~/.bashrc ~/.bash_profile ~/.profile 2>/dev/null
```

### The secret check

Before opening any file you plan to edit, run this check on it.
It prints the file and line number of each line that may hold a credential, never the line itself.

```bash
woods_secret_lines() {
  awk '{ line = tolower($0) }
    (line ~ /(token|secret|password|passwd|api_key|apikey|private_key|authorization|bearer)[a-z_]*["\047]?[ \t]*(=>|=|:)[ \t]*["\047]?[^ \t$(]/ &&
     (line !~ /env(\.fetch|\[)/ || line ~ /env\.fetch\([^)]*,/)) || line ~ /:\/\/[^\/@ \t]+@/ {
      print FILENAME ":" FNR
    }' "$@"
}
woods_secret_lines config/initializers/woods.rb config/application.rb .mcp.json
```

A file with no output may be opened and edited.
For a flagged file, do not open it: give the user the line numbers from the inventory and the change to make.

## 2. Show the plan and ask

Show one table before any edit, naming keys and lines, never values:

| Place | File and line | Change |
|---|---|---|
| Switch | `config/initializers/woods.rb:NN` | Remove `config.console_mcp_enabled = true`, or set it to `false` |
| Other Console options | same file | Optional: remove the `console_*` lines; they are inert once the switch is off |
| Client entry | `.mcp.json`, entry `<name>` | Remove the entry; keep the Index Server entry |
| Hand-written Rack mount | `config/application.rb:NN` | Remove the `Woods::Console::RackMiddleware` line |
| Token (`WOODS_CONSOLE_MCP_TOKEN`) | file and line only | The user removes it and its secret-store copy |
| Client header | `.mcp.json`, entry `<name>`, header `Authorization` | Removed with the entry; the user rotates the token |
| Launcher file | `~/.woods/console.yml` | Move aside to `console.yml.disabled` |
| Process | `Procfile.dev:NN`, Compose service `<name>` | Remove the entry that runs `woods:console` or `woods-console-mcp` |

Then ask the user to approve the plan, or to pick the rows to apply.
Stop if they decline.

## 3. Make the edits

- Edit only the approved rows, one at a time.
- Remove a Claude Code entry with `claude mcp remove <name> -s project` (or `-s local`, `-s user`); it prints no values.
- For another client file, edit it only if the secret check passed for it; otherwise the user removes the entry.
- Keep the automatic Rails mount: with the switch off it passes every request through to the application.
- Leave Rails credentials, CI secrets and password managers to the user; say which key to remove there.
- To review an edit, rerun the inventory.
  Do not show a diff of a file that held a secret: use `git diff --stat` for it.

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
Rerun the inventory: it should report no `console` entry and no `console_mcp_enabled` line.
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

Report each place found by file, line and key, what changed, and what the user still has to do.
The user's part covers secret stores, flagged files and other machines.
Include the check results and the `woods_status` call.
Point the user to the alternatives above for the questions they used the Console for.

Canonical guide: [Turning the Console off](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_MCP_SETUP.md#turning-the-console-off).
