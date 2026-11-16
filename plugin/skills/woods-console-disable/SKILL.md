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

- **Ask before every edit.** Show the file, the line or key and the change first; edit only after the user agrees.
- **Never delete a file.** Edit lines out, or move a file aside (`console.yml` to `console.yml.disabled`).
  The edit helper below removes only its own temporary file.
- **Never print a value.** Every command prints names and locations only: file, line number, key name.
  Use only the commands below, which follow that rule.
  Do not print the environment, a resolved Compose configuration or a configuration object.
- **What a file is decides what you may do with it.** See "File classes"; a secret check result never grants access.
- **Give the user a manual step for any edit that needs a file read.** See "Manual steps", then carry on.
- **Name keys, not values,** in the plan, the questions and the handoff.
- **Leave the Index Server alone.** Keep every `woods-mcp`, `woods-mcp-start` and `woods-mcp-http` entry as it is.
- **Touch only Console lines.** Do not reformat a file, reorder keys or change unrelated settings.
- Files outside the repository (user-level client configuration, `~/.woods/`) need the user's explicit go-ahead.

## File classes

Decide by what a file is, before you run anything on it.

**Open.** You may open and edit these, unless the secret check flags the file:

- Ruby configuration that sets Console options: `config/initializers/*.rb`, `config/application.rb`,
  `config/environments/*.rb`.
- Ruby under `app/` or `lib/` that mounts `Woods::Console`.

**Key only.** Never open or display these; list key names with the commands below.
Remove an entry from plain JSON by key with `woods_mcp_remove`; every other edit here is a manual step.

- MCP client JSON: `.mcp.json`, `.vscode/mcp.json`, `.cursor/mcp.json`, `~/.claude.json` and other client files.
  An entry can hold a token under its env or headers key.
- Client files in other formats (TOML, YAML, JSON with comments).
- Compose files, Procfiles and scripts that start the Console.
- Env-file templates: `.env.example`, `.env.sample`, `.env.template`.
- Shell profiles, and `~/.woods/console.yml`.

**Never.** Never open, search or edit these; name the key the user should look for there.

- `.env` and every other `.env.*` file except the templates above.
- `config/credentials*`, `config/master.key`, `*.key`, `*.pem`.
- Anything under a `credentials`, `secrets` or `.secrets` directory.

The secret check can only add caution: a hit on an Open file makes its edit a manual step.
A clean check never moves a file to another class, and never makes a Key only or Never file safe to open.
The check matches common forms only, so a file it passes can still hold a credential.

## Manual steps

When an edit cannot be made without reading a file's contents, do not make it.
Give the user the precise step: the file, the line number or key path, and the key to remove or the setting to change.
Then go on with the rows you can make safely.

The token is always a manual step.
Name `WOODS_CONSOLE_MCP_TOKEN` and each file and line where the inventory found it.
Ask the user to remove it there, in every `.env` file and in the secret store, and then to rotate it.
Never open a place where it is set.

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
Each prints file names, line numbers and key names only, and skips every Never file.

```bash
# Never files: no search below reads them
woods_skip=(--exclude='.env*' --exclude='credentials*' --exclude='master.key' --exclude='*.key' --exclude='*.pem'
  --exclude-dir=credentials --exclude-dir=secrets --exclude-dir=.secrets)
# Switch, other Console options and hand-written Console code
grep -rnoE "console_mcp_[a-z_]+|console_embedded_read_tools|Woods::Console::[A-Za-z]+" "${woods_skip[@]}" \
  config lib app 2>/dev/null
# Processes and scripts that start the Console
grep -rnoE "woods:console|woods-console-mcp|exe/woods-console" "${woods_skip[@]}" \
  Procfile* bin script docker-compose*.y*ml compose*.y*ml .mcp.json 2>/dev/null
# Console environment variable names, in any tracked or untracked file
grep -rnoE "WOODS_CONSOLE_(MCP_TOKEN|CONFIG|UNSAFE_EVAL)|CODEBASE_CONSOLE_CONFIG" "${woods_skip[@]}" . \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tmp --exclude-dir=log 2>/dev/null
# The same names in env-file templates
grep -HnoE "WOODS_CONSOLE_(MCP_TOKEN|CONFIG|UNSAFE_EVAL)|CODEBASE_CONSOLE_CONFIG" \
  .env.example .env.sample .env.template 2>/dev/null
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

Before opening an Open file, run this check on it.
It prints the file and line number of each line that may hold a credential, never the line itself.

```bash
woods_secret_lines() {
  awk '{ line = tolower($0) }
    (line ~ /(token|secret|password|passwd|api_key|apikey|private_key|authorization|bearer)[a-z_]*["\047]?[ \t]*(=>|=|:)[ \t]*["\047]?[^ \t$(]/ &&
     (line !~ /env(\.fetch|\[)/ || line ~ /env\.fetch\([^)]*,/)) || line ~ /:\/\/[^\/@ \t]+@/ {
      print FILENAME ":" FNR
    }' "$@"
}
woods_secret_lines config/initializers/woods.rb config/application.rb
```

A flagged file stays closed: its edit is a manual step, with the line numbers from the inventory.
Tell the user that a flagged line may hold a credential to rotate.
Run the check on Open files only; it changes nothing for Key only and Never files.

## 2. Show the plan and ask

Show one table before any edit, naming keys and lines, never values:

| Place | File and line or key | Change | By |
|---|---|---|---|
| Switch | `config/initializers/woods.rb:NN` | Remove `config.console_mcp_enabled = true`, or set it to `false` | Agent |
| Other Console options | same file | Optional: remove the `console_*` lines; inert once the switch is off | Agent |
| Hand-written Rack mount | `config/application.rb:NN` | Remove the `Woods::Console::RackMiddleware` line | Agent |
| Client entry, plain JSON | `.mcp.json`, key `mcpServers.<name>` | Remove the entry; keep the Index Server entry | Agent |
| Client entry, other format | file, entry `<name>` | Remove the entry | User |
| Client header | `.mcp.json`, key `mcpServers.<name>.headers.Authorization` | Goes with the entry; rotate the token | User rotates |
| Token (`WOODS_CONSOLE_MCP_TOKEN`) | each file and line found | Remove it there, in `.env` files and the secret store; rotate it | User |
| Launcher file | `~/.woods/console.yml` | Move aside to `console.yml.disabled` | Agent |
| Process | `Procfile.dev:NN`, Compose service `<name>` | Remove the entry that runs `woods:console` or `woods-console-mcp` | User |

An Agent row in a file the secret check flagged becomes a User row.
Then ask the user to approve the plan, or to pick the rows to apply.
Stop if they decline.

## 3. Make the edits

- Edit only the approved rows, one at a time.
- Open file: open it and edit the Console line.
- Remove a Claude Code entry with `claude mcp remove <name> -s project` (or `-s local`, `-s user`); it prints no values.
- Remove an entry from another plain JSON client file by key, with the helper below.
  It names the file, the key path and the names left, never a value.
- Move `~/.woods/console.yml` aside with `mv`, without opening it.
- Every other row is a manual step (see "Manual steps"): Compose files, Procfiles, scripts, env-file templates,
  client files in other formats, and any file the secret check flagged.
- Keep the automatic Rails mount: with the switch off it passes every request through to the application.
- Leave Rails credentials, CI secrets and password managers to the user; say which key to remove there.
- To review an edit, rerun the inventory and use `git diff --stat`.
  Never show a diff of a Key only file.

```bash
# Usage: woods_mcp_remove FILE MAP NAME, for example: woods_mcp_remove .vscode/mcp.json servers rails-console
woods_mcp_remove() {
  local f=$1 m=$2 n=$3 tmp
  if [ -L "$f" ]; then echo "$f is a symbolic link: make this a manual step"; return 1; fi
  jq -e --arg m "$m" --arg n "$n" '(.[$m] // {}) | has($n)' "$f" > /dev/null 2>&1 \
    || { echo "$f has no entry $m.$n, or is not plain JSON: make this a manual step"; return 1; }
  jq . "$f" 2> /dev/null | cmp -s - "$f" || [ "${WOODS_REFORMAT_OK:-}" = 1 ] \
    || { echo "$f: jq would reformat the whole file: ask the user"; return 1; }
  tmp=$(mktemp "$f.XXXXXX") && cp -p "$f" "$tmp" \
    && jq --arg m "$m" --arg n "$n" 'del(.[$m][$n])' "$f" > "$tmp" 2> /dev/null && mv "$tmp" "$f" \
    || { [ -n "$tmp" ] && rm -f "$tmp"; echo "$f: edit failed, file unchanged: make this a manual step"; return 1; }
  echo "$f: removed $m.$n; $m keeps: $(jq -r --arg m "$m" '.[$m] | keys | join(",")' "$f")"
}
```

`MAP` is the key that holds the entries: `mcpServers` in most clients, `servers` in `.vscode/mcp.json`.
For a symbolic link, a file that is not plain JSON or a missing entry, the helper changes nothing.
The edit is then a manual step.
jq writes the whole file back, so the helper first checks that jq keeps its layout.
If it would not, ask the user whether a reformatted file is acceptable.
Run `WOODS_REFORMAT_OK=1 woods_mcp_remove ...` only after they agree; otherwise it is a manual step.

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
The report holds file paths, line numbers and key names only, never a value or a line's contents.
The user's part covers every manual step: the token, secret stores, flagged files and other machines.
Include the check results and the `woods_status` call.
Point the user to the alternatives above for the questions they used the Console for.

Canonical guide: [Turning the Console off](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_MCP_SETUP.md#turning-the-console-off).
