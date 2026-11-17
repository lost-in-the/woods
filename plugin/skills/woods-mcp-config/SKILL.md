---
name: woods-mcp-config
description: Connect MCP clients (.mcp.json, Claude Code) to a Rails app's Woods index.
---

# Woods MCP configuration

For builds containing #590 (included in Woods 2.1), managed preflight retains
intended bundle settings, project receipts omit the unused user config directory,
and watcher ownership tolerates Git checkout umasks. Check the installed revision
before relying on this. Keep the supporting executable for update/removal before
a permanent downgrade; never delete a receipt to bypass a conflict. Use a private
real directory for plan files when the system temporary path is a symlink. Follow
the [portability guidance](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/AGENT_SETUP.md#managed-claude-code-configuration).

## Managed configuration availability

`woods-agent-config` (#407) is available in Woods `2.0.0.beta3`. First record the
installed version and test `bundle exec woods-agent-config --help` in the
selected application bundle. When supported, use its saved setup/update/remove
plan and explicit client/scope/root selection; apply the reviewed plan within
the user's existing authorization. Do not infer ownership from a server name
or repair edited managed sections by overwriting them. Plans and recovery
journals contain private configuration bytes. See the canonical
[managed configuration runbook](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/AGENT_SETUP.md#managed-claude-code-configuration)
for host/Compose preflight, actual Claude file locations, conflict recovery,
and removal. Preserve manual setup for older installed versions.

## Preflight

```bash
bundle info woods
bin/rails woods:validate
bin/rails woods:stats
```

This skill describes the Woods 2.x line; the authoritative minimum version lives in the marketplace entry. Operate only against capabilities the recorded installed version provides. Detect the MCP client, app root, host vs Docker Rails process, the filesystem context that contains the application bundle and index, and whether live-data access is actually required.

Configure the Index Server only.
It reads generated code context and exposes 16 tools (15 before Woods `2.2.0`, which adds `path`).
The Console MCP server was removed in Woods 2.2.0; never configure it, on any version.
When a client already has a Console entry, offer to remove it as the
[removal page](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_REMOVED.md#cleaning-up-after-an-upgrade)
describes, and keep the Index Server entry.

Initialization guidance (#402) is available in Woods `2.0.0.beta3`; check the
installed gem before expecting MCP `instructions`. Supporting servers provide
a short workflow through initialization or modern discovery; protocol
`2024-11-05` omits it. Missing instructions alone are not a connection failure.
Keep normal protocol negotiation and use the
[agent guide](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/AGENT_GUIDE.md)
when unavailable. See the
[initialization contract](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/MCP_SERVERS.md#initialization-guidance).

The packaged Index process does not load Rails initializers. Session and Notion
tool registration requires an explicitly configured custom/embedded process;
application configuration alone does not wire them into a separate executable.
Use `bin/rails woods:notion_sync` for ordinary application export and verify
`tools/list` for custom capabilities. See the
[process boundaries](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/MCP_SERVERS.md#conditional-index-capabilities).

## Shape 1: Index-only

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

Use this shape for any stdio-capable MCP client, adapted to the client's configuration location. `woods-mcp-start` validates and launches; it does not install or auto-restart.

MCP registration does not start automatic indexing. Existing readers observe
published generations without reconnecting; separately verify the watcher owner,
startup catch-up, and a real edit. Native launcher/Puma installation (#538) is
included in Woods `2.0.0`: check installed `woods-watch` and generator help
before offering it. Preserve the existing external service in Docker/Grove and
keep its source/index aligned across switches. See
[automatic maintenance](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/AUTOMATIC_MAINTENANCE.md).

Writer-version provenance (#323) is available in Woods `2.0.0.beta3`; check the installed
gem version's release notes before expecting `index.woods_version` in `woods_status`. It reports
the last manifest publisher, independently of `server.version`. Treat missing/null
as unknown and see [writer provenance](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/PUBLISHED_INDEX.md#manifest-writer-provenance).

Verify semantic retrieval separately from structural `ready`. A reachable
provider and bootstrap `hydrated` can coexist with empty stores. If the recorded
reader supports #549, inspect `retriever.corpus` for local record counts and
known-empty diagnostics; absent or unknown counts require checking embedding
artifacts. These fields do not certify embedding coverage. See the
[readiness distinction](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/RETRIEVAL_GUIDE.md#semantic-corpus-diagnostics).

When Woods is installed only in Docker, prefer running the server through the application container:

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

Use a host-side bundle only after verifying Ruby, the application bundle, and the index are available on the host. Always pass the path visible to the process that runs `woods-mcp`. Prefer an explicit index path on all versions. Woods `2.0.0` includes `WOODS_OUTPUT` as a fallback after the positional path and `WOODS_DIR`; check the installed version's configuration guide before relying on it. `woods-mcp-start` still refuses a missing path rather than selecting its working directory.

For linked worktrees, verify source/index alignment and the extraction's Git
branch and exact SHA. Preserve the complete shared Git layout and select the
worktree-specific directory when using the installed version's `WOODS_GIT_DIR`
override; the shared root selects the primary checkout's HEAD. Follow the
[worktree mount guide](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/TROUBLESHOOTING.md#git-directory-mounts-for-linked-worktrees).

From Woods `2.2.0` (check the installed version's release notes), register each
checkout with its own index: `woods-mcp-start` refuses an index that belongs to a
different checkout unless given `--allow-mismatch` or
`WOODS_MCP_ALLOW_MISMATCH=1`, and a branch difference only warns. Verify with
`woods_status.identity.client_matches`.

From Woods `2.2.0` (check the installed version's release notes), `woods_status`
summarizes the other linked checkouts by state by default; pass
`worktrees: "list"` to see each entry.

A read-only index mount is sufficient for structural tools. The `reload` tool for in-memory semantic retrieval also takes Woods' shared on-disk writer lock, so the MCP process needs write access to the index directory. Without it, reload returns a typed degraded error and keeps serving the previous aligned generation. Either grant that access or restart the MCP process after publishing a new embedded index.

In Woods 2.1, the `:local` preset also returns
degraded on reload because snapshot vectors and SQLite metadata cannot refresh
atomically together. Restart `woods-mcp` after `woods:embed`; write access alone
does not resolve this case. See the [backend matrix](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/BACKEND_MATRIX.md#persistence-story).

For host MCP reading a container daemon's shared index, foreign heartbeat trust
(#321) is available in Woods `2.0.0.beta3`. Verify the installed gem version's release notes before
offering `WOODS_WATCH_TRUST_FOREIGN_HOST=1` in the MCP environment. It makes
`woods_status.watch.alive` use the same bounded freshness policy as task readers;
see [cross-host liveness](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/WATCH_DAEMON.md#cross-host-liveness).

## Verify

Reconnect through the client so it performs its supported MCP negotiation.
Clients on current MCP protocol revisions use per-request metadata/discovery; older clients initialize first — the
server supports both.
Call `woods_status`, `search`, and `lookup`.

Do not use an isolated raw JSON-RPC request as proof of MCP health. Do not claim conditional Index schemas are callable.

Canonical guide: [MCP_SERVERS.md](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/MCP_SERVERS.md).

## Lexical retrieval capability check

Lexical retrieval is available from `2.0.0.beta3`. Before proposing it, verify the installed gem
exposes `Woods::Configuration#retrieval_mode` and its matching guide documents
`WOODS_RETRIEVAL_MODE`. Keep the installed-version preflight; do not infer support
from the plugin version or an unreleased checkout.

When supported, put `WOODS_RETRIEVAL_MODE=lexical` in the environment of the
process launching Index MCP (stdio or HTTP). A Rails initializer alone is not
loaded by that process. Restart the MCP server after changing its environment, then confirm `woods_status.retriever.mode` reports `lexical`. A beta3 no-provider error may omit this option; it does not mean embeddings are required for explicit lexical mode.
See the [retrieval guide](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval)
for the supported contract, checked against the installed gem version.

## Explicit package or path scope

Check the connected tool's advertised input schema before sending `packages` or
`source_paths`; older installed gems may not support them. When present, both
`search` and `codebase_retrieve` apply explicit scope before candidate limits.
Use published nearest package names or application-relative directory prefixes,
then inspect `applied_scope` and search completeness. Unknown packages are argument
errors; unsupported custom vector adapters degrade instead of running a global
query. Scoping can hide relevant cross-boundary relationships, so broaden the
request deliberately when the task needs them. See the
[scope contract](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/RETRIEVAL_GUIDE.md#explicit-package-and-source-path-scopes).

## Source-content freshness (Woods 2.0.0.beta3; #405)

Check installed-version support before using `woods-extract` or the optional
`woods_status.source_check` argument. With support, inspect
`index.source_freshness`: `current`, `drifted` or `unknown`. Repeated edits to an
already-dirty file can leave the porcelain fingerprint unchanged. A quick scan
limit may justify one `source_check: "deep"`; unavailable source/private keys or
unproved boot/consumer coverage remain unknown. A fresh `bundle exec woods-extract full`
inside the application environment establishes preboot evidence. Never publish
`.source-inputs.key`, silently change its permissions, or delete queued edits to
hide diagnostics. Follow [source freshness](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/SOURCE_FRESHNESS.md).

Woods 2.1 reports `unavailable` with
`source_manifest_too_large` when source evidence exceeds its serialized-size
limit. The code index remains usable. Follow `inspect_source_limits`, inspect
`unavailable.size_bytes` / `unavailable.limit_bytes`, and retain the limitation;
an identical full extraction or a deeper scan cannot fix oversized evidence.
An oversized launcher handoff cannot establish verified preboot capture.

## Partial search and GraphQL lookup (included in Woods 2.1)

Check the installed reader revision before relying on these repairs. Unscoped
search skips an individual unit it needs but cannot read, retains readable matches,
and reports successful partial completeness with
`reason: "unreadable_or_corrupt_source"`. Empty partial results do not prove
absence. Identifier-only search can use summaries without validating unit
bodies; run `woods:validate` for damage. Explicit package/source-path scope
still requires readable bodies across its full-unit preflight. Corrupt
index-wide artifacts return a typed error. Supporting `lookup` also accepts
`type: "graphql"`, but returns the unit's concrete type; use that type for follow-up checks.
See the [search contract](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/MCP_SERVERS.md#search-completeness).

## Compact evidence capability check

Inspect the connected server's installed tool schemas before using `evidence` on
`lookup` or `codebase_retrieve`; older releases do not provide these controls.
When available, explicit `compact` selects complete published source spans and
`outline` lists declared APIs. Read omission/provenance fields and follow the
returned typed, SHA-guarded `full_evidence` lookup for verification. Published-unit
coordinates are not physical file offsets; unknown generation remains unknown.
Keep full-source access available. See the canonical
[evidence contract](https://github.com/lost-in-the/woods/blob/v2.1.0/docs/RETRIEVAL_GUIDE.md#compact-published-evidence-and-api-outlines).

### Origin policy compatibility

In Woods `2.0.1`, HTTP preflight and the SDK share one captured policy. List the
browser's exact origin, including its port, for cross-origin requests; portless
entries additionally permit same-authority
traffic. Include a non-loopback MCP endpoint authority and restart after edits.
Do not disable SDK protection or rewrite Origin/Host to make a request pass.
Follow the [2.0.1 HTTP guide](https://github.com/lost-in-the/woods/blob/v2.0.1/docs/MCP_HTTP_TRANSPORT.md#browser-origins-dns-rebinding-defense)
and verify both preflight and authenticated dispatch.

### HTTP configuration diagnostics in 2.0.1

Verify the installed version, loaded gem path and any Git revision. In Woods
`2.0.1`, invalid origin settings, including invalidly encoded entries, refuse at
boot. The HTTP executable reports one configuration diagnostic and exits 2.
Correct the named entry and restart; keep authentication and origin checks enabled. Follow the
installed revision's canonical `docs/MCP_HTTP_TRANSPORT.md` for accepted origins.

Use whitespace-free literal origin entries; explicit lists replace browser
defaults, and wildcard patterns are unsupported. Preserve the real Host behind
proxies. Verify both preflight and bearer-authenticated dispatch against the
[2.0.1 HTTP compatibility guide](https://github.com/lost-in-the/woods/blob/v2.0.1/docs/MCP_HTTP_TRANSPORT.md#origin-configuration-compatibility).
For applications staying on 1.6, use `1.6.4` and its
[HTTP compatibility guide](https://github.com/lost-in-the/woods/blob/v1.6.4/docs/MCP_HTTP_TRANSPORT.md#origin-configuration-compatibility);
configuration normalization differs between the two lines. A plugin update does
not update either server's installed gem.
