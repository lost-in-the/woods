# Agent setup runbook

Use this runbook when a coding agent installs or configures Woods 2.0 in an existing Rails repository. The goal is a small, reviewable change and a working structural Index Server. Semantic retrieval and live-data access are separate opt-ins.

## Default decision

Install the structural index only unless the user explicitly asks for another capability.

| Capability | Default | Requires explicit approval when agent-operated |
|---|---:|---|
| Extract Rails code and schema structure | On | No |
| Local or hosted embeddings | Off | Yes: adds a service, credentials, cost, or generated vectors |
| Console MCP | Off | Yes: boots Rails and can read live application data |
| HTTP MCP transport | Off | Yes: expands network exposure |
| Purging or rebuilding durable stores | Off | Yes: can remove Woods-owned data |

## 1. Preflight without changing files

Read the repository's agent instructions first. Then record:

```bash
git status --short --branch
ruby --version
bundle exec rails --version
bundle exec rails runner 'puts Rails.application.class.name'
```

Also determine:

- whether Rails commands run on the host or through Docker Compose;
- which Compose service owns the Rails process, if applicable;
- the database adapter and whether migrations are allowed in this environment;
- whether `woods` already appears in the Gemfile or lockfile;
- whether `config/initializers/woods.rb`, Woods migrations, or Woods tables already exist;
- whether `tmp/woods/` is ignored or intentionally published.

If the worktree contains unrelated changes, preserve them. Do not overwrite an existing initializer or migration without showing the conflict to the user.

## 2. Choose the installation path

Use structural-only setup when the user wants code navigation, runtime Rails structure, dependencies, flows, or blast-radius analysis. Fourteen tools register in the normal packaged launch without an embedding provider.

If the user wants ranked discovery through `codebase_retrieve`, offer [explicit lexical mode](RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval) over the published index without a provider or embeddings. Check that the installed version supports it, set `WOODS_RETRIEVAL_MODE=lexical` in the MCP process environment, restart that server, and verify `woods_status.retriever.mode`. Keep structural-only setup as the default unless this mode is requested.

For semantic matching, discuss local Ollama or hosted OpenAI and the appropriate vector store separately; adding a provider still requires authorization. See [Backend matrix](BACKEND_MATRIX.md).

Do not infer permission to configure Console MCP from a request to “set up Woods” or “set up MCP.” The Index Server reads generated code context; the Console Server can read live data.

## 3. Install on a branch

Create or switch to the branch requested by the repository owner. Select the
published version using the [installation guide](GETTING_STARTED.md#1-install-the-gem).
Before stable 2.x is published, use the exact published prerelease constraint
from RubyGems; `~> 2.0` will not select a beta or release candidate.
Use the selected version's tag documentation and verify its capabilities before
configuring features described on `main`.

Add only the development dependency. The following constraint applies **after a
stable 2.x release is published**:

```ruby
# Gemfile
group :development do
  gem "woods", "~> 2.0"
end
```

Run the repository's normal dependency command:

```bash
bundle install
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
```

Do not broadly update unrelated gems. Review the Gemfile and lockfile diff before continuing.

## 4. Generate and inspect

```bash
bin/rails generate woods:install
git diff -- config/initializers/woods.rb db/migrate
```

The generator emits a legacy application migration for:

- `woods_units`
- `woods_edges`
- `woods_embeddings`

Woods 2's shipped structural index and storage backends do not use those application tables. For a new default installation, propose removing the generated migration from the working tree and get approval before doing so. Keep or run it only when repository history shows an older/custom integration uses the tables; confirm name conflicts and obtain explicit migration authorization first.

Follow repository policy for generated files and schema changes. Never run a production migration as an incidental setup step.

## 5. Extract and validate

Use the same execution environment and boot variables the Rails app normally needs:

```bash
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

If extraction fails, reproduce Rails boot and eager loading outside Woods before changing configuration:

```bash
bin/rails runner 'puts Rails.application.class.name'
bin/rails runner 'Rails.application.eager_load!; puts "eager load ok"'
```

Fix one root cause at a time. Do not suppress an application boot error to make extraction appear successful.

## 6. Configure the Index MCP client

Prefer a project-scoped configuration so the executable, bundle, and index all belong to the same repository:

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "./tmp/woods"],
      "cwd": "/absolute/path/to/the-rails-app"
    }
  }
}
```

For Docker, extraction runs inside the Rails container. If Woods is installed only there, configure the client to launch `docker compose exec -T app bundle exec woods-mcp /app/tmp/woods` with the host application root as `cwd`. Use a host-side `bundle exec woods-mcp-start` only after verifying the host has a supported Ruby, the application bundle, and a host-visible index. In either mode, supply the path visible to the server process.

Reconnect the client and call `woods_status`. Confirm a current generation and non-zero unit counts before claiming setup works.

### Managed Claude Code configuration

`woods-agent-config` is available from Woods `2.0.0.beta3`.
Check `bundle exec woods-agent-config --help` in the selected application bundle;
use the manual client configuration below when it is absent. The supported
client format is Claude Code (tested with 2.1.267).

Create a private plan, inspect its paths and diff, then apply that same plan:

```bash
bundle exec woods-agent-config setup --client claude --scope project \
  --root "$PWD" --instructions CLAUDE.md,AGENTS.md --plan /tmp/woods-setup.json --diff
bundle exec woods-agent-config apply /tmp/woods-setup.json \
  --client claude --scope project --root "$PWD"
```

Choose a new, unused plan filename for each preview. Preview writes only the
requested plan file; it does not edit managed configuration. Plans contain the
complete replacement bytes, including unrelated settings, and use mode 0600:
keep them private and remove them when no longer needed. `show FILE` prints its
summary; `show FILE --diff` checks the original snapshots and prints a unified
diff. Applying a changed snapshot fails rather than replacing the new content.
A repeated identical setup makes no configuration edits.

| Selection | Managed files |
|---|---|
| `--scope project` | `<root>/.mcp.json`, explicitly selected `<root>/CLAUDE.md` and/or `AGENTS.md`, `<root>/.woods-agent-config.json` ownership receipt |
| `--scope user` | `~/.claude.json`, explicitly selected `~/.claude/CLAUDE.md`, application-specific receipt in `~/.claude/` |

With `CLAUDE_CONFIG_DIR`, user scope uses that directory's `.claude.json`,
`CLAUDE.md`, and receipt instead. Instruction edits are opt-in with
`--instructions`; existing selections carry forward on update. The command
configures the Index Server. Client trust and project approval remain Claude
Code settings; apply does not change them.

Preflight runs the selected installed bundle, validates its index, and checks
its actual registered capabilities. It does not boot Rails or contact an
embedding provider. The bundle must already resolve in frozen mode; prepare
its lockfile separately if Bundler reports a mismatch. Host mode uses the
application's absolute Gemfile and index paths. `--index tmp/woods` is relative
to the selected root. For Compose, also select `--mode compose --service web
--container-root /app`; run the configuration command where Docker Compose can
access that project. Preflight verifies the index and installed gem inside that
service. Both host and container subprocesses have time limits.

Use `update --plan FILE` with the same client/scope/root and the desired launch
options to change the owned entry or instruction selection. Update explicitly
records the current template and installed-gem evidence; background hooks never
update configuration. `remove --plan FILE` previews deletion of owned content
and does not require the application bundle or index to remain available.
Use `--name NAME` consistently if the installation uses a nondefault server name.
Apply each operation's saved plan with the same explicit client/scope/root.

Ownership comes from the receipt and exact managed section, not from a server
named `woods`. Existing unowned names, edited managed content, malformed JSON,
duplicate markers, symlinks, and concurrent edits cause conflicts. Preserve the
receipt for future update/removal. Unrelated servers, hooks, settings,
instruction text, permissions, and line-ending conventions are retained;
changing JSON may reformat its whitespace.

Included in Woods `2.0.0`: apply and recovery coordinate on the actual
managed file paths, including user configuration and shared instruction files.
Two application roots sharing those files cannot apply overlapping plans at the
same time. A competing operation reports a conflict; after it finishes, create a
fresh preview if the saved plan's snapshots changed. Both applications keep
their own ownership receipts. Do not delete an active coordination lock.

Writes use atomic replacement per file and a private recovery journal beside
the receipt. The plan summary names all adjacent `.woods.lock` files, the
receipt `.lock`, and the `.pending` journal;
a lock file may remain after completion. Multiple files are not one atomic
transaction. An ordinary write failure restores original files when safe; an
interruption or concurrent edit can retain the journal. Resolve reported
conflicts, then use `recover --client claude --scope project --root "$PWD"`
(or the original user scope). Recovery refuses to overwrite concurrent edits.
Keep journals private because they contain original configuration bytes. A plan
whose recovery journal would exceed 8 MiB is refused before any managed file
is changed; reduce the selected configuration before applying.

## 7. Verify useful behavior

Use a class known to exist in the application:

1. Call `search` to obtain its exact identifier and type.
2. Call `lookup` with that identifier and type to confirm source and metadata are present.
3. Call `dependents` with depth 1 or 2 to confirm graph edges are queryable.

If `codebase_retrieve` reports that semantic search is disabled, that is expected for structural-only setup. Do not configure credentials merely to remove the message. If lexical retrieval was requested, verify its mode with `woods_status` and make one `codebase_retrieve` call against the published index.

## 8. Offer automatic index maintenance

Within the owner's setup authorization, select one development startup owner.
Follow [managed startup](WATCH_DAEMON.md#managed-development-startup): Puma for
simple Rails startup, a verified existing Foreman command/Procfile, or the existing
external Docker/Grove supervisor. The launcher/generator are **included in Woods
`2.0.0`**; check installed `woods-watch --help` and generator help first.
Preserve `bin/dev`; a file that only starts Rails does not consume a Procfile.
For older gems use their raw task with a restart-capable external supervisor,
not a bare Foreman entry.

The watcher catches up missed changes, maintains the structural index as files change, and publishes generations the Index MCP server detects automatically. Ordinary edits then need no manual re-extraction or MCP restart. It should run in development, not production.

Report these boundaries in the handoff:

- raw tasks exit 75 for boot-captured changes; managed launchers absorb that restart;
- managed mode rejects idle TTL and parks ownership conflicts without taking over;
- container bind mounts may require `WOODS_WATCH_POLL=1`;
- semantic vectors still require `woods:embed_incremental`;
- without a resident watcher, the fallback is `woods:incremental` after changes.

## Stop and ask before

Get explicit user approval before:

- enabling Console MCP or granting access to a live database;
- enabling `console_embedded_read_tools`, `console_sql`, or `console_query`;
- adding an API key, hosted embedding provider, Qdrant, pgvector, or Ollama service;
- exposing MCP over HTTP, selecting bind addresses, or configuring bearer tokens;
- overriding a purge guard or deleting/rebuilding Woods durable data;
- overwriting an existing Woods initializer, migration, or MCP configuration;
- changing production or shared infrastructure.

## Handoff report

Return a concise report the owner can verify:

```text
Woods version:
Branch:

Files changed:
- Gemfile / lockfile:
- initializer:
- migration/schema:
- MCP client configuration:

Commands run:
- install:
- migrate:
- extract:
- validate/stats:

Verified capabilities:
- Index Server connected: yes/no
- woods_status current: yes/no
- search/lookup/dependents checked: yes/no
- retrieval: disabled/lexical/semantic (provider when semantic)
- Console MCP: disabled/enabled (authorization)
- automatic structural updates: disabled/enabled (owner and actual startup command)
- served root/index and completed startup catch-up:
- edit and planned restart observed through existing MCP connection:
- worktree/Grove switching verified (if applicable):
- post-edit hooks / session freshness checks / context hints: separate enablement

Follow-up or unresolved risk:
```

Never report a capability as enabled solely because its schema exists in source. Report what the packaged executable actually registered and what you called successfully.

## Copyable prompt for an installation agent

> Install Woods 2.x in this Rails repository using https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md. Select a published version and follow that version's tag documentation and supported capabilities. Start with read-only preflight and preserve unrelated changes. Default to the structural Index Server; do not enable embeddings, Console MCP, HTTP transport, secrets, or purge overrides without asking me. Inspect generated files before migrating, run extraction and validation in the app's normal execution environment, configure a project-scoped MCP server in the same filesystem context as the application bundle and index, and verify `woods_status`, `search`, `lookup` with the discovered identifier and type, and `dependents`. Finish with the runbook's handoff report.

## Related guides

- [Edit client adapters](CLIENT_HOOKS.md) for separately opt-in Claude/OpenCode edit hooks; MCP setup does not enable them.

- [Getting started](GETTING_STARTED.md) for the human walkthrough.
- [MCP servers](MCP_SERVERS.md) for client-specific configuration and server boundaries.
- [Upgrade to Woods 2.0](UPGRADING_TO_2.md) for an existing 1.x installation.
- [Troubleshooting](TROUBLESHOOTING.md) for extraction and connection failures.
