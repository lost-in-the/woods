---
name: woods-setup
description: Install, upgrade, and first-run-configure the Woods Rails code-intelligence gem — Gemfile entry, generator, extraction, index verification, MCP registration, and the 1.x-to-2.x upgrade path. Use whenever a user wants Woods added to or upgraded in a Rails app, or asks for a runtime-accurate codebase index for AI tools, even without naming Woods' components.
---

# Woods setup

Install a structural Index Server first. Embeddings and Console MCP are separate opt-ins.

## Managed configuration availability

`woods-agent-config` (#407) is available in Woods `2.0.0.beta3`. First record the
installed version and test `bundle exec woods-agent-config --help` in the
selected application bundle. When supported, use its saved setup/update/remove
plan and explicit client/scope/root selection; apply the reviewed plan within
the user's existing authorization. Do not infer ownership from a server name
or repair edited managed sections by overwriting them. Plans and recovery
journals contain private configuration bytes. See the canonical
[managed configuration runbook](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md#managed-claude-code-configuration)
for host/Compose preflight, actual Claude file locations, conflict recovery,
and removal. Preserve manual setup for older installed versions.

## Preflight

Read repository instructions and preserve unrelated changes. Record:

```bash
git status --short --branch
ruby --version
bundle exec rails --version
bundle info woods 2>/dev/null || true
bundle exec rails runner 'puts Rails.application.class.name'
```

This skill describes the Woods 2.x line; the authoritative minimum version lives in the marketplace entry. Operate only against capabilities the recorded installed version provides, and for an older gem use the documentation on that version's tag. Determine host vs Docker execution, database adapter, migration policy, existing Woods config/tables, and which filesystem context contains the application bundle and `tmp/woods/`.

## Install and inspect

Choose the published version using the canonical
[installation guide](https://github.com/lost-in-the/woods/blob/main/docs/GETTING_STARTED.md#1-install-the-gem)
and its linked README release table. When only prereleases are published for
2.x, add the exact published beta/RC constraint shown there to the development
group; `~> 2.0` does not select prereleases. Use `gem "woods", "~> 2.0"` only after
a stable 2.x release is published. Follow the selected version's tag docs and
verify installed capabilities; installing this plugin does not install `main`
features. Then run:

```bash
bundle install
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
bin/rails generate woods:install
git diff -- config/initializers/woods.rb db/migrate
```

The generator creates an initializer and a legacy application migration for `woods_units`, `woods_edges`, and `woods_embeddings`. Woods 2's shipped structural index and storage backends do not use those application tables. For a new default installation, propose removing the generated migration and obtain approval first. Keep or run it only when repository history proves an older/custom integration uses those tables, after normal migration authorization and conflict checks.

Do not broadly update gems or overwrite existing configuration.

## Upgrading from 1.x

When the preflight records an installed 1.x version, this is an upgrade, not an install. Woods 2.0 changes observable index identifiers, the publication layout, vector-store reconciliation, and the supported MCP surface, so plan a clean re-index and follow the canonical runbook: [UPGRADING_TO_2.md](https://github.com/lost-in-the/woods/blob/main/docs/UPGRADING_TO_2.md).

Before changing the Gemfile: back up any shared or durable index and agree on a rollback window — never upgrade one in place. After `bundle update woods`, run a full `bin/rails woods:extract` (not incremental; the old index is not a valid baseline across the major), then `woods:validate`. With embeddings configured, re-embed from scratch into a store matching the configured model; expect identifier-level churn in anything that consumed 1.x identifiers (exports, saved queries, downstream tooling). Verify MCP clients against the new surface rather than assuming 1.x tool behavior.

## Extract and verify

Structural setup needs no embedding provider:

```bash
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

If extraction fails, reproduce Rails boot and eager loading first. Do not inspect internal payload files when Woods tasks provide the check.

Writer-version provenance (#323) is available in Woods `2.0.0.beta3`; check the installed
gem version's release notes before expecting `woods_status.index.woods_version`. When present,
it names the last manifest publisher; `server.version` names the MCP reader.
Missing/null means unknown. A matching version after an incremental run never
replaces a required full upgrade extraction. See [writer provenance](https://github.com/lost-in-the/woods/blob/main/docs/PUBLISHED_INDEX.md#manifest-writer-provenance).

Configure the Index Server with the application bundle, absolute app `cwd`, and an index path visible to that process. For a host-installed bundle:

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "./tmp/woods"],
      "cwd": "/absolute/path/to/app"
    }
  }
}
```

When Woods is installed only in Docker, launch it through the application service instead:

```json
{
  "mcpServers": {
    "woods": {
      "command": "docker",
      "args": ["compose", "exec", "-T", "app", "bundle", "exec", "woods-mcp", "/app/tmp/woods"],
      "cwd": "/absolute/host/path/to/app"
    }
  }
}
```

Reconnect and call `woods_status`, then `search`, `lookup`, and `dependents` for a known class. The normal Index Server has 14 tools. `codebase_retrieve` requires configured embeddings in semantic mode; see the lexical capability check below for the opt-in provider-free mode.

Offer one automatic-maintenance owner within the setup scope. The managed launcher,
watcher generator, and Puma adapter (#538) are **unreleased after `2.0.0.beta4`**.
Record the loaded gem path and revision, then verify `bundle exec woods-watch
--help` and `bin/rails generate woods:watch --help` before using them. Follow the
[managed startup runbook](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#managed-development-startup):
Puma for simple Rails startup, an explicit verified Foreman command/Procfile, or
the existing external Docker/Grove supervisor. Preview before applying within
existing authorization. Preserve `bin/dev`; never claim an unused Procfile is
active. Keep the portable receipt with generated files and respect edit conflicts.
Puma installation supports the normal default `config/puma.rb` route; an existing
environment-specific file or custom `-C` route needs a different explicit owner.
The unreleased #542 guard checks plugin files in the active gem, including Git/path
bundles. Older gems without the plugin skip watcher startup. Existing generated
Puma setups need an explicit `--operation update --mode puma` (preview first) to
upgrade the owned guard in place; repeating setup preserves it. The wrapper and
Foreman entry still require a supporting gem. Remove owned setup before a permanent
downgrade; do not hand-edit the receipt or its managed block.
Run setup in the normal application bundle environment. The unreleased #540 fix
preserves `BUNDLE_PATH`, `BUNDLE_APP_CONFIG`, and group selection during preflight;
older Git builds may falsely report missing gems. Check the loaded revision
before changing persistent Bundler settings to work around that error.
For an interrupted install, use the generator's `--operation recover --pretend`
before applying recovery; preserve journals when concurrent edits block it. The
Rails generator command boots the app first: use the runbook's direct bundled
Ruby recovery helper when an initializer prevents boot.

On older gems, use the raw task only with a restart-capable external supervisor;
do not place it bare in Foreman, where exit 75 stops the whole stack. Use the
application's real Rails task entrypoint without a preceding `environment` task.
Managed mode rejects idle TTL and does not take over conflicting owners. Verify
startup catch-up, an edit, and a planned restart through the existing MCP reader;
for Grove, also verify worktree/source/index alignment. Docker may need polling.
Semantic vectors still need `woods:embed_incremental`; hooks and MCP registration
do not install watcher startup.

Foreign-host heartbeat trust (`WOODS_WATCH_TRUST_FOREIGN_HOST=1`, #321) is available in
Woods `2.0.0.beta3`.
Check the installed gem version against its release notes before offering it;
do not assume installing this plugin upgrades the gem. For a supporting version,
follow [cross-host liveness](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#cross-host-liveness)
and set the opt-in in each task/MCP reader of a shared container index. Explain
the 15-minute crash-detection delay and preserve one supervisor per daemon.

For slow bind mounts, check whether the installed version documents
`WOODS_WATCH_POLL_INTERVAL` before suggesting it; this setting is available in Woods
`2.0.0.beta3`. Where supported, a positive value such as `2.5` reduces
polling frequency at the cost of detection latency. Use the installed preflight version to select tagged documentation; the
[canonical watch guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md)
tracks current source and may describe unreleased behavior.

The plugin ships opt-in refresh and session-start hooks. The expanded refresh
contract (#408) is available in Woods `2.0.0.beta3`: first verify the installed
gem exposes `woods:hook_refresh` through the actual application command. Do not
infer support from the plugin version. With support, edits to standard services,
controllers, jobs, views, concerns, locales, supported tests/lib files, routes,
and packages queue incremental work; boot/config/schema edits request a fresh
full extraction. A live daemon defers without acknowledging the queue. Failed or
deferred events remain under `<output>/hook-pending/` and retry on the next
relevant edit. Inspect `hook.log` before retrying; never delete pending events to
hide a failure. Prefer `woods:watch` for sustained edits because hook coverage
increases Rails boot frequency.

Both hooks require an existing index and `WOODS_HOOKS_ENABLED=1`; disable with
`WOODS_HOOKS_DISABLED=1`. Use `WOODS_HOOK_RAKE="docker compose exec -T app bundle
exec rake"` for a container-only bundle and `WOODS_OUTPUT` for a non-default
index. The host needs Bash and either jq or Ruby, not the application bundle.
The refresh worker's deadline starts after the complete event input has been
collected, validated, and queued; it does not bound input collection. It includes
subsequent batches, but cancelling Docker exec does not prove its container
process stopped. See the [hook deadline and retry contract](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#hooks-for-agent-sessions).
Source freshness (#405) is available in Woods `2.0.0.beta3`: verify the installed command
exposes `woods:source_status` and `woods-extract` before using it. Supporting
SessionStart hooks check source content and report missing/failed evidence as
unknown; silence does not acknowledge queued refresh work. Follow the [hook guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#hooks-for-agent-sessions)
for transport, retry and custom-root limits.

## Ask before expanding scope

For pgvector, match the provider output and migration dimensions within 1–2,000. Default `text-embedding-3-large` output (3,072) needs an explicit smaller provider width or another backend; never silently truncate vectors. Early adapter/generator refusal is unreleased after `2.0.0.beta3`, so check the installed revision. See the [dimension contract](https://github.com/lost-in-the/woods/blob/main/docs/CONFIGURATION_REFERENCE.md#pgvector-postgresql).

Require explicit approval before adding Ollama/OpenAI, pgvector/Qdrant, secrets, Console MCP/live-data access, HTTP transport, or purge overrides. The `:local` preset avoids cloud keys but requires the `sqlite3` gem, an installed/running Ollama service, and a pulled model (`ollama pull nomic-embed-text` by default); `:shared_filesystem` avoids sqlite3 but still uses Ollama. Recommend `gem "tokenizers", "~> 0.5"` for exact counting on dense Ruby source, while stating that it is optional.

## Handoff

Report the Woods version/revision, branch, files changed, commands/results, index
path, MCP calls verified, semantic retrieval and Console status, and unresolved
risks. For automatic maintenance record the owner, actual startup command,
completed catch-up, observed edit/restart, and worktree verification. Report
refresh hooks, session checks, and context hints separately. Never infer
availability from source schemas or a live process alone.

Canonical runbook: [AGENT_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md).

## Lexical retrieval capability check

Lexical retrieval is available from `2.0.0.beta3`. Before proposing it, verify the installed gem
exposes `Woods::Configuration#retrieval_mode` and its matching guide documents
`WOODS_RETRIEVAL_MODE`. Keep the installed-version preflight; do not infer support
from the plugin version or an unreleased checkout.

When supported and authorized, offer explicit lexical mode for ranked discovery
over extraction output without provider credentials or vectors. Semantic mode
remains the default; setting up embeddings is a separate choice.
See the [retrieval guide](https://github.com/lost-in-the/woods/blob/main/docs/RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval)
for the supported contract, checked against the installed gem version.

## Explicit edit adapters (Woods 2.0.0.beta3; #409)

Check the installed gem exposes `woods:hook_refresh` before enabling hooks.
Claude's registered wrapper covers one documented edit path; OpenCode 1.18.27
has a separate native `.js` registration wrapper importing Woods' shipped
adapter. Its verified patch metadata carries all added/updated/deleted/moved
paths. Keep the complete plugin directory available, preserve opt-in/disable
settings and pending events, and inspect the generation and hook log before
claiming refresh. Unsupported tool shapes and symlink paths need watch or an
explicit extraction. Do not install native client registration without the
user's setup request. Follow [client hooks](https://github.com/lost-in-the/woods/blob/main/docs/CLIENT_HOOKS.md).

## Optional context hints

Check installed `bundle exec woods-hook-context --help` before enabling
`WOODS_HOOK_CONTEXT_ENABLED=1`; this capability is available in Woods `2.0.0.beta3` and the
plugin does not upgrade the gem. Context and refresh opt-ins are independent;
`WOODS_HOOKS_DISABLED=1` disables both. Native Claude context is synchronous and
bounded, with served-generation and pre-refresh/unknown labels. Verify candidate
dependents and suggested tests manually; silence is not no impact. Do not clear
refresh queues when optional hints time out. See the canonical
[context guide](https://github.com/lost-in-the/woods/blob/main/docs/WATCH_DAEMON.md#optional-bounded-context-hints)
for output/time limits, container root mapping and emitted-hint suppression.
