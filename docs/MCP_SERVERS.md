# MCP servers

Woods provides two MCP servers with different purposes and trust boundaries. Use the Index Server for codebase work. Enable the Console Server only when an agent must inspect live Rails data.

## Choose a server

| Question | Index Server | Console Server |
|---|---|---|
| What does it answer? | Code structure, resolved Rails behavior, dependencies, flows, and graph questions | Live model, schema, count, aggregate, sample, and optional read-only query questions |
| What does it read? | A generated Woods index | A booted Rails app and its database |
| Does it boot Rails? | No | Yes |
| Packaged default | 14 tools | 9 tools |
| Normal setup | Recommended | Disabled |
| Main risk | Generated index may contain source and schema details | Responses may contain live application data |

Do not enable Console MCP to compensate for a stale or missing index. Extract or refresh the Index Server instead.

## Index Server

### Prepare the index

Run these commands wherever the Rails application normally boots:

```bash
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

For embedding-free ranked retrieval, start Index MCP with
`WOODS_RETRIEVAL_MODE=lexical`. This opt-in reads the published extraction units;
it does not probe providers or load vectors. `woods_status.retriever.mode` reports
`lexical`, and inactive embedding fields are `null`. The default semantic mode
keeps its existing embedding setup and failure behavior. See
[retrieval modes](RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval) for scoring,
query limits and measured tradeoffs. Both packaged stdio and HTTP launches honor
the setting; put it in the MCP process's environment, not just a Rails initializer.

The stdio server can then run outside Rails. Point it at the index root (`tmp/woods/` by default), not at an internal generation or payload directory.

### Configure a stdio client

Prefer the application's bundle and a project-scoped configuration:

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "./tmp/woods"],
      "cwd": "/absolute/path/to/your-rails-app"
    }
  }
}
```

`woods-mcp-start` checks that the directory and published manifest exist and that the index belongs to the checkout it was launched in (see [served index identity](#served-index-identity)), then replaces itself with `woods-mcp`. It does not install dependencies or restart a crashed process.

The MCP client owns this reader process. Automatic index maintenance has its own
[watcher startup](WATCH_DAEMON.md#managed-development-startup): configuring MCP
does not enable it. A running reader sees new published generations on subsequent
calls without reconnecting. Verify a real edit, not only a successful connection;
see [automatic maintenance](AUTOMATIC_MAINTENANCE.md).

`woods_status.index.woods_version` identifies the last publisher of the served
manifest; `server.version` identifies the running MCP reader. Missing writer
provenance is `null`. See [manifest writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance).

You can launch the server directly when the client already handles preflight:

```bash
bundle exec woods-mcp ./tmp/woods
```

Keep stdout reserved for MCP protocol messages. Diagnose startup failures from stderr or by running the same command in a terminal.

### Client configuration locations

Supporting development builds offer preview/apply/update/remove ownership for
Claude Code project or explicit user configuration. See
[managed configuration](AGENT_SETUP.md#managed-claude-code-configuration) for
`woods-agent-config`, host/Compose preflight, conflict handling, and recovery.
Manual configuration remains available for older gems and other clients.

MCP clients expose project or user-level server settings in different locations. Use project scope when available, preserve the `command`, `args`, and absolute `cwd` semantics above, and translate only the surrounding client-specific format. Woods is model-independent: compatibility depends on the client supporting MCP stdio or Streamable HTTP, not on whether the connected model is from OpenAI, Anthropic, Google, xAI, or another provider.

Client configuration formats can change independently of Woods. If a client rejects otherwise valid JSON, check that client's current MCP documentation.

### Docker process and path rule

Extraction runs inside the Rails container. When Woods is installed only in that container, prefer launching the Index Server through it too:

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

Compose resolves the project from `cwd`; `-T` disables its pseudo-TTY while stdin remains connected to MCP. This server uses the container path and does not require Ruby or Woods on the host.

A host-side `bundle exec woods-mcp-start` is also valid, but only when the application bundle is installed on the host and the output is host-visible:

```text
Rails container: /app/tmp/woods
Volume mapping:   ./tmp:/app/tmp
Host MCP path:    /absolute/host/project/tmp/woods
```

Always choose the path visible to the server process. See [Docker setup](DOCKER_SETUP.md).

### Verify the connection

Reconnect the client, then call:

1. `woods_status` to confirm the index and generation;
2. `search` with a class name;
3. `lookup` with an identifier returned by search.

Prefer a real MCP client's connection flow over a hand-written JSON-RPC pipe. Modern MCP 2026-07-28 requests carry per-request protocol metadata and can use `server/discover` without an initialization handshake; older clients still use `initialize`. A valid raw smoke test must implement one complete flow rather than sending an isolated `tools/list` or `tools/call` request.

### Malformed stdio frames

Included in Woods `2.1.1`: both stdio servers run the SDK transport through `Woods::MCP::StdioTransport`, which answers a frame that is not valid UTF-8, or whose JSON escapes decode to invalid UTF-8 (an unpaired surrogate), with the JSON-RPC parse error (`-32700`), logs one `rejected frame` line on stderr, and keeps serving. The frame is never rewritten. Earlier releases exited with status 1 on such a frame (the `mcp` gem strips and parses it unguarded), and `woods-mcp-start` has no restart loop, so the server stayed down until the client reconnected. A frame that is merely not JSON is still answered by the SDK's own parse error.

### Served index identity

With several checkouts of one repository, a server's name does not say which
index it serves. The Index Server says so itself:

- **At connect.** `instructions` lead with one line naming the checkout
  (directory name and path), the branch the index was extracted on, the
  generation number and its `updated_at`, and the Woods version (and git
  revision, for a git-loaded build) that wrote the index. Mismatch warnings
  follow it, each prefixed `WARNING:`. The identity is read once, at startup;
  the generation can advance while connected.
- **In `woods_status`.** The report leads with `identity`: `root` (recorded
  application root), `repository_root` and `root_name` (the checkout),
  `root_source`, `branch`, `git_sha`, `generation`, `generation_updated_at`,
  `woods_version`, `woods_revision`, `woods_revision_dirty`, then
  `client_matches`, `client_match_reason`, `client_root`, `client_branch`,
  `branch_matches`, `mismatch_allowed` and `build` (writer versus reader).
  For a call routed with [`root`](MCP_WORKTREE_SETUP.md#one-server-several-worktrees-root),
  the client is that worktree.

**Which checkout.** The checkout containing the root the manifest records,
when this process can reach it; otherwise the checkout containing the index
directory (an index written before roots were recorded, or one written inside
a container and read through a bind mount). A checkout is the nearest directory
holding `.git`, so an application in a subdirectory belongs to the repository
above it and a worktree nested inside another checkout is its own. The client
is the checkout containing the launcher's working directory.

`client_matches` is `true` or `false` when both checkouts are known, and `null`
when either is not (`client_match_reason` says which: `root_not_recorded`,
`recorded_root_unreachable`, `client_outside_checkout`).

**Root mismatch refuses.** `woods-mcp-start` exits 1 when `client_matches` is
`false`, naming both checkouts. Pass `--allow-mismatch`, or set
`WOODS_MCP_ALLOW_MISMATCH=1`, to serve another checkout's index on purpose: the
launcher then connects with a warning on stderr, and the instructions and
`woods_status` carry the warning. `woods-mcp` itself never refuses; it reports.

**Branch differences warn.** A branch that differs from the client checkout's is
a warning, not a refusal: detached HEADs and one worktree per branch are
normal. A detached HEAD on either side compares as unknown.

**Builds.** Each manifest records the writer's `woods_version`, and for a
git-loaded build `woods_revision` and `woods_revision_dirty` (see
[manifest writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance)).
When the writer is another build, the instructions, `woods_status.identity.build`
and the launcher say so:

- another version string: "Index written by Woods X, this reader is Y; run
  `woods:extract` or request a re-index."
- the same version string at another revision: "Index written by a different
  Woods build (<rev>); …"

The index is still served; backward-compatible reading is not offered. A read
that fails this reader's payload guards (for example
`typed unit identity mismatch`) is answered with that message and error code
`index_build_mismatch` instead of `corrupt_artifact`; the original text is in
`_meta.read_error`. `woods_status.index.incremental` reports
`cause: "build_mismatch"` and a `build mismatch (...)` status rather than
"needs full extraction" when this reader cannot use a baseline another build
wrote. A released gem records no revision, so two released builds of one version
compare as they always did.

Identity costs two small file reads (`generation.json` and the manifest) and
the client checkout's `HEAD` file before the handshake. A git-loaded reader runs
`git rev-parse` on its own checkout only when the manifest records a revision.
The manifest is the one that same `generation.json` read names, and
`woods_status` takes both from the generation its call pinned, so generation,
commit and writer build always describe one snapshot even while a new
generation is being published.

### Initialization guidance

The Index Server supplies a short, client-neutral `instructions` field through
the SDK's `initialize` response and modern `server/discover`. It leads with the
[served index identity](#served-index-identity), then describes the
status → discovery → inspection → bounded traversal → source-verification
workflow, and lists only the tools actually registered by this server.
Instructions are stable for an unchanged index and tool registration, and
bounded to 2,048 UTF-8 bytes (a long identity is truncated; `woods_status` has
it whole). Building the text does not probe providers, extract code, or write
configuration.

Registration alone does not establish retrieval readiness: check `woods_status`
before using `codebase_retrieve`, including after reload. The guidance grants
no extraction, configuration-change, or Console authorization. Detailed usage
belongs in the [agent guide](AGENT_GUIDE.md).

This addition is included in Woods `2.0.0`. The SDK omits `instructions`
when negotiating protocol `2024-11-05`; that behavior is preserved. Older gems,
legacy clients, and clients that do not show server instructions can use the
agent guide or investigation skill. Leave protocol negotiation enabled rather
than pinning a newer version solely to obtain guidance.

### Structural and semantic readiness

`ready` describes the published structural index, not corpus size or extraction
coverage. An intentionally empty application can have a valid, ready zero-unit
index; inspect `structure` counts and extraction diagnostics when zero is
unexpected. A reachable embedding provider
and bootstrap state `hydrated` do not establish that semantic stores contain
data. Supporting readers also report `retriever.corpus`: locally known vector
and metadata entry counts, counts by type, and whether those stores are empty,
populated, or unknown. These are stored records (including chunks), not a count
of extracted units with verified embedding coverage. Positive counts do not
prove complete coverage or working provider access. See
[semantic corpus diagnostics](RETRIEVAL_GUIDE.md#semantic-corpus-diagnostics).

### Startup and cache hydration

The Index Server answers `initialize` before it warms its caches. The
warm-up (the reader's manifest, summary, graph and identifier map, plus the
lexical corpus in `WOODS_RETRIEVAL_MODE=lexical`) runs on one background
thread that starts once the `initialize` response has been written, so the
handshake takes milliseconds on any index size. Before this change the
server warmed first and answered `initialize` after 9-13 s on an index of
~11,000 units; a client with a short handshake probe (Claude Code gives up
at 5 s) recorded the server as rejecting `initialize` and connected only on
a later pass.

`woods_status` reports the warm-up under `hydration`: `state` is `warming`,
`ready` or `failed` (with `error.class` and `error.message`), next to
`warmup` (`after_handshake`, `before_handshake` or `none`), `started_at`,
`finished_at` and `duration_seconds`. The `bootstrap` section is unchanged
and still describes the semantic stores.

A tool call that arrives during the warm-up waits for it to finish, up to
`WOODS_MCP_HYDRATION_WAIT_SECONDS` (default 30), then dispatches against the
warmed caches. After a failed warm-up it answers from the cold reader. Past
the cap the call no longer waits on anything the warm-up holds:

- Every reader-backed tool (`lookup`, `search`, the traversals, resources and
  the rest) answers from the cold reader: every cache fills lazily on first
  use, so the answer is the same, only slower, and nothing is answered from a
  partially built cache.
- `codebase_retrieve` in lexical mode needs the whole corpus, and building
  it is the warm-up's job. Rather than build a second copy (as slow as the
  warm-up and doubling its memory), it answers a non-error, retryable
  `warming` result: `structuredContent.data.status` is `warming`,
  `retryable` is `true`, `retry_after_seconds` is set, `hydration` carries
  the `woods_status` section, and there are no sources, so it can never pass
  for "no matches". The text says the same. A retry waits for the warm-up
  again, up to the cap. In semantic mode there is no corpus warm-up and
  `codebase_retrieve` answers as before.

`woods_status` and `reload` never wait for the warm-up. A `reload`, or a
newly published generation, that needs the warm-up's generation pins
released does not queue behind it either: the warm-up gives its pins up,
lets the reload or refresh through, and starts again on the generation that
is then current. A client that skips the legacy
handshake (`server/discover`) starts the warm-up with its first tool call.
While the warm-up parses a large index, concurrent calls can pause for a
garbage-collection cycle of a few seconds; that is latency, not a wrong
answer.

Embedding the server: `Woods::MCP::Server.build(warmup:)` takes
`:after_handshake` (the default), `:before_handshake` (warm synchronously
inside `build`, before the transport starts, the behaviour of earlier
releases; a warm-up exception propagates out of `build`) or `:none`. `true`
and `false` still mean the default and `:none`. Over stdio, use
`Woods::MCP::StdioTransport`: it starts the warm-up only after the handshake
response is flushed. On the HTTP transport the warm-up starts as the
`initialize` handler returns.

The self-map server (`bin/woods-self-mcp`) is the same Index Server, so a
launch that finds a built map answers `initialize` at once too. A first
launch still builds the map before the server starts: the Index Server
cannot boot against a directory that holds no published generation yet.

### Tools (31 — 15 registered in the packaged default)

The Index Server defines 31 schemas across core and conditional capabilities. The normal packaged executable registers the 15 tools below; the remaining schemas require the specialized wiring described afterward.

| Tool | Use it for |
|---|---|
| `woods_status` | Index health, generation, counts, and retrieval readiness |
| `search` | Discover identifiers by regex, prefix, suffix, source, or metadata |
| `lookup` | Fetch one exact unit with source, metadata, and relationships |
| `dependencies` | Traverse what a unit depends on (`depth`, `types`, `via` narrow; `max_nodes`, `max_edges` budget work; `limit`, `offset` page) |
| `dependents` | Traverse what depends on a unit (`depth`, `types`, `via` narrow; `max_nodes`, `max_edges` budget work; `limit`, `offset` page) |
| `structure` | Summarize structural relationships around a unit |
| `trace_flow` | Follow a request, job, mail, or other execution flow |
| `diagram` | Mermaid text of one unit for a pull request or a review: `neighbourhood`, `schema`, `lifecycle` or `impact`, each with its own `depth`; refused over its budget, never truncated ([diagrams](MCP_TOOL_COOKBOOK.md#diagrams)) |
| `framework` | Inspect relevant Rails or installed gem source |
| `recent_changes` | Find indexed units changed recently |
| `graph_analysis` | Structural reports: orphans, dead ends, hubs, cycles, bridges, cross-database edges, volatile dependencies, undeclared package edges |
| `domain_clusters` | Discover connected domains in the graph, paged with `limit`, `offset`, and `member_limit` |
| `pagerank` | Find structurally central units |
| `reload` | Reload a newly published generation without restarting the client |
| `codebase_retrieve` | Natural-language retrieval with embeddings or explicit lexical mode over extraction output |

When an identifier appears in multiple extraction types, `framework` reads its
framework-source bucket and `recent_changes` reads each selected type bucket.
Their paths and metadata belong to that selected bucket. When session tracing
is configured, newly recorded requests use the dispatched controller's runtime
class name; the fallback for requests without an instance respects Rails acronym
inflections. Existing trace records are unchanged. Controller lookup and root
outgoing-edge selection preserve the controller type. Downstream references and the shared context pool still use
bare identifiers. If a dependency encountered within the requested depth has
multiple published types, `session_trace` returns an `ambiguous_identity` tool
error naming the identifier and candidate types, with no partial context. This
also prevents an earlier dependency from occupying a later controller’s context
key. Unrelated collisions do not block a trace, and a known controller root keeps
its controller identity. A controller absent from the index remains in the
timeline without a source reference, so another type cannot fill that reference.
Candidate discovery and source reads use one pinned
generation. Corrupt or missing listed artifacts retain the `internal_error`
failure boundary; they do not prove uniqueness or become `ambiguous_identity` errors.
Use `depth: 0` for the request timeline, or inspect candidates with typed `lookup`
calls. Re-extraction does not remove a legitimate cross-type collision. Successful
traces retain their existing identifiers and response shape; target identity has
not been migrated globally. These corrections are available in `2.0.0.beta3`.

The server also exposes MCP resources and resource templates for indexed units. Tool descriptions returned by MCP are the parameter-level source of truth; [Agent guide](AGENT_GUIDE.md) explains selection strategy.

Structural reads can use a read-only index mount. The `reload` tool is different:
its transactional in-memory retrieval refresh takes the same on-disk writer lock as
extraction and embedding, so the MCP process needs write access to the index
directory. If it cannot acquire or create that lock, reload returns a typed degraded
error and continues serving the previous aligned generation; it never swaps in a
partial or empty replacement. Grant write access for live reloads, or restart the MCP
process after publishing a new embedded index.

**Included in Woods 2.1:** the `:local` preset combines snapshot vectors with
SQLite metadata, which cannot be refreshed together atomically in the running
server. Its `reload` returns a degraded error and retains the previous aligned
state even when the directory is writable. Restart `woods-mcp` after
`woods:embed` to load the new vectors. See the [backend matrix](BACKEND_MATRIX.md#persistence-story).

### Resource identity and damaged generation markers

**Included in Woods 2.1 (#593):** unit resource identifiers may contain
slashes, such as `views/posts/show.html.erb` or `GET /posts/:id`. Encode the
whole identifier as one URI segment (`%2F` for `/`) in
`codebase://unit/{identifier}`. Raw multi-segment paths, dot traversal segments,
double encoding and backslashes remain invalid. Type resource names cannot
contain slashes.

A held-open server returns `corrupt_artifact` for a malformed published
generation marker or an unavailable/outside-root payload pointer. Repeated
calls retain that error rather than presenting the cached generation as current.
An already pinned request can finish against its known generation. New requests
resume after a valid marker is restored; a leftover flat root manifest is not
substituted for a missing or invalid named payload. Run
`woods:validate` and restore a known-good publication or complete a fresh
extraction; do not point the marker at an arbitrary payload directory.
Legacy flat indexes without a generation marker remain supported.

### Graph-analysis pages

Included in Woods `2.0.0`: `graph_analysis` enforces its advertised default
of 20 rows per section. Pass `limit` and `offset` to page one selected `analysis`
or each section of `analysis: "all"`. Explicit limits also bound nested hub
`dependents` lists. Older servers may return every section row when `limit` is
omitted; pass a limit explicitly when supporting both versions.

JSON responses retain `<section>_total`, `<section>_offset` (when positive), and
`<section>_truncated: true` whenever a page omits rows before or after it. Markdown,
plain, and Claude responses show the same total and offset on last and empty
pages. For example, offset 20 with limit 5 over 25 published orphans shows
`5 of 25 from offset 20`; offset 100 shows `0 of 25 from offset 100`. An empty
page does not mean the section has no findings. These totals describe the
published report arrays, which can themselves be bounded during extraction;
they do not establish complete source-reference coverage.

### Domain cluster pages

`domain_clusters` returns clusters largest first, ties broken by name, so the
order is stable for a given generation. `limit` (default 20) and `offset` page
the clusters. `member_limit` (default 50) caps the members, entry points and boundary edges listed per cluster;
a list cut by it carries `members_omitted`, `entry_points_omitted` or `boundary_edges_omitted`, and `member_count` stays the true
size. Raise `member_limit` to read the rest of a large cluster.

`total` is the number of clusters after `types` and `min_size`. The shared
`completeness` object reports `total_matches` and `has_more`; the last page
reports `has_more: false`. `WOODS_DOMAIN_CLUSTERS_LIMIT` and
`WOODS_DOMAIN_CLUSTERS_MEMBER_LIMIT` change the defaults. The server computes
clusters once per published generation and exact `min_size` and `types`, so
paging does not recompute them.

### Search completeness

Search responses retain `query`, `result_count`, and `results`; `result_count`
is the number returned, not an estimated total. The additive `completeness`
object describes the requested types, literal filters, and fields in the pinned
generation. This contract is included in Woods `2.0.0`.

| `reason` | `status` | `has_more` | `total_matches` |
|---|---|---|---|
| `exhausted` | `complete` | `false` | Exact count |
| `result_limit` | `partial` | `true` | `null` (unknown) |
| `scan_budget` or `regex_timeout` | `partial` | `null` (unknown) | `null` (unknown) |
| `unreadable_or_corrupt_source` (included in Woods 2.1) | `partial` | `null` (unknown) | `null` (unknown) |

`matched_lower_bound` counts distinct observed `(type, identifier)` matches,
including at most one lookahead match beyond `limit`. A result-limit response
therefore establishes another match; an exactly full page can instead be
complete if the requested domain is exhausted. Deep lookahead shares the
deep-field scan budget with the initial scan and retains round-robin scanning
across types. Search does not count the entire omitted tail or offer pagination.
**Included in Woods 2.1 (#593):** `search.types` accepts concrete unit types
such as `graphql_mutation` and `gem_source`, plus the directory-family aliases
`graphql` (all four GraphQL types) and `rails_source` (Rails and gem sources).
Aliases expand the same way with or without a package/source-path scope.
Results always carry the actual stored type, so their `(type, identifier)` can
be passed to `lookup`; an unknown type returns `invalid_params` instead of an
apparently complete empty result. This corrects the older unscoped family
labels. Retrieval tools continue to use their own documented concrete-type
filters; search aliases do not change those contracts.

**Included in Woods 2.2 (#969):** `graphql` and `rails_source` are the only
family aliases. `search.types: ["route"]` returns `route` units only, not the
`route_file` units that share the `routes/` directory; pass `route_file` for
those. `routes` is not a type and returns `invalid_params`. `recent_changes`
filters `types` the same way and labels each result with its unit's own type
(`route_file`, `gem_source`, `graphql_mutation`) instead of its directory name.

**Included in Woods 2.1:** typed `lookup` also accepts the `graphql` family
alias. The returned unit keeps its concrete type, such as `graphql_mutation`;
prefer that concrete type for follow-up identity checks.

**Included in Woods 2.1.1:** `lookup` refuses a `type` it cannot resolve with
`invalid_params` and lists `accepted_types` in `_meta`, the same contract as
`search`, instead of answering `not_found` with a hint to search. An untyped
`lookup` of an identifier published under more than one type still returns one
unit (the type directory that sorts last) and names every type in
`_meta.ambiguous_types`; pass the intended `type` to choose.

Identifier matches are ranked by how well they match, not by the order of type
directories or summary files: the exact identifier first, then an exact short
name (the last `::` segment, a table's name after `table:`, or a path segment;
a route is named by its path, not its HTTP verb), then prefixes, then any other
match, with shorter names first within each rank. The order is the same for
every generation of the same source, and a broad query no longer cuts the exact
name or its table from the page. Deep-field matches follow identifier matches
in scan order.

**Deep-field scan budget.** A `metadata` or `source_code` search reads unit
bodies one by one. By default it reads every candidate unit in the requested
types, so a mid-size index is searched completely, and stops early only past
256 MiB of unit JSON or 10 seconds of wall time. On 10,000-unit indexes of 75
to 95 MB, a full `source_code` scan took 0.3 to 0.8 seconds with a warm page
cache and 1.3 to 4.6 seconds from a cold one; the caps cover roughly 2.5 times
such an index. `WOODS_SEARCH_MAX_SCAN` replaces both caps with an exact unit
count. An in-process caller of `IndexReader#search` can pass `max_scan:` for
one call (a positive Integer, in unit bodies), which takes precedence; the MCP
tool uses `WOODS_SEARCH_MAX_SCAN` or the default.

A deep search's response (JSON `scan`, and the Ruby result) reports
`scanned_units` and `scanned_bytes` read of `candidate_units` queued,
`total_units` in the requested types and scope, the `budget` applied
(`units`, `bytes`, `seconds`; `null` is unbounded) and, when a cap stopped it,
`limit_hit` (`units`, `bytes` or `seconds`). A stopped scan keeps
`status: partial` and `reason: scan_budget`; its `hint` names how many units
were read of how many and `WOODS_SEARCH_MAX_SCAN`. When nothing matched, the
hint says plainly that zero results is not evidence of absence: the unread
units were never searched.

All partial responses retain `partial: true` and include a narrowing `hint`.
JSON exposes these fields; Markdown, plain text, and Claude formats label the
returned count, stopping reason, known/unknown remainder, and total explicitly.
Narrow `types`, literal `exact_prefix`/`exact_suffix`, or deep `fields` before
using discovery as exhaustive evidence. Completeness applies to this index and
query domain, not to unindexed application code.

**Included in Woods 2.1:** an individual unit that unscoped search needs but
cannot decode or open is skipped. Search retains readable matches and returns
successful partial completeness with reason `unreadable_or_corrupt_source`;
an empty partial answer does not establish absence. Identifier-only matches can
use published summaries without opening unit bodies, so search is not an
artifact-integrity check. Inspect `woods_status` and run `woods:validate`.
Explicit package/source-path scope first reads the full unit set, once per loaded
generation, and still returns an error if that preflight encounters a damaged
body; a scoped search that reuses the read treats a body damaged since like an
unscoped search does.

Damaged index-wide artifacts, such as a manifest or type index, remain
`isError: true` with `_meta.error_code: "corrupt_artifact"`. Their `_meta.completeness` has
`status: "unknown"`, `reason: "unreadable_or_corrupt_source"`, and `null` for
`has_more`, `total_matches`, and `matched_lower_bound`; no successful empty
result is substituted. Inspect `woods_status` and run `woods:validate`.

### Notion sync completeness

`notion_sync` reports its outcome in the same `completeness` shape as search,
with one addition: `status: "failed"`, which search never emits.
`total_errors` is the uncapped error count, and `errors` lists at most ten.

| `reason` | `status` | `has_more` | `synced` |
|---|---|---|---|
| `exhausted` | `complete` | `false` | `true` |
| `page_errors` (some pages written or already current) | `partial` | `true` when `total_errors` exceeds the listed errors | `true` |
| `nothing_synced` | `failed` | same as above | `false` |

Non-complete runs also set `partial: true` and a `hint`. The result is JSON
only; no Markdown or plain rendering exists for this tool.

### Dependency graph coverage

`dependencies` and `dependents` return relationships recorded in the published
index, not an exhaustive call graph or source-reference index. Extraction combines
runtime reflection with selective source scanning; arbitrary method-body constant
references (including references to generic PORO and library classes) may have no
edge. No dependents, a test-only dependent, or a completed traversal does not prove
there are no production callers. Verify important absence claims in source.

A supporting post-2.0 writer recovers additional [constant source references](EXTRACTOR_REFERENCE.md#constant-source-references)
(included in Woods 2.1). Upgrading the reader alone cannot add relationships
to an old index. The coverage warning still applies.

Supporting servers expose the annotated, paginated traversal result in
`structuredContent.data` for every renderer, including the default packaged
stdio and HTTP servers. Read `data.total_is_exact`, `data.graph_coverage`, budget
counters and optional explanation witnesses there; `content[0].text` and
`structuredContent.text` keep the same human-readable rendering. No `format`
tool argument is needed or accepted. This additive data payload is included in
Woods `2.0.0`; verify the installed response before relying on it. Older
human-renderer responses can carry only text. The structured nodes and witnesses
cover the same page, not an additional traversal or an unpaginated graph.

Successful responses carry `graph_coverage` with `scope: "published_relationships"`,
`source_references: "not_exhaustive"`, and a human-readable `notice`. Text formats
show the same notice, including compact, root-only and empty-page responses.
This response metadata and the total exactness field below are included in Woods
`2.0.0`; older servers need the same conservative interpretation.

### Dependency traversal budgets

`dependencies` and `dependents` walk breadth-first in stored graph order. The
walk defaults to `max_nodes: 1000` (including the root) and `max_edges: 10000`;
callers can select 1–10,000 nodes and 1–100,000 edge checks. The node budget
counts distinct nodes admitted after filters. Every candidate edge is charged
before filtering, including duplicates, cycles, and the forward-edge checks
needed to match a reverse `via` filter. Thus restrictive filters cannot bypass
the edge budget. Nodes at the requested `depth` are recorded without reading
their adjacency lists.

When further expansion would exceed a budget, JSON reports `partial: true`,
`partial_reason: "node_budget"` or `"edge_budget"`, and `traversal_budget` with
`max_nodes`, `max_edges`, `visited_nodes`, and `visited_edges`. Text renderers
also identify the partial traversal. Already discovered nodes remain in the
answer, but an empty `deps` array in a partial answer does not prove a leaf.
Exact-budget walks that finish all requested work are complete and have no
`partial` marker.

`limit` (default 50) and `offset` only page that discovered result; they never
change the walk budget or depth. On a partial traversal, `nodes_total`, when
present for pagination, counts the discovered prefix, **not the full reachable
graph**. Every successful response includes `total_is_exact`: false for a
budget cutoff, true when the requested walk finishes, even when its page is
truncated or empty. It is independent of `limit`/`offset` and is present for
unpaged answers too. Partial text answers say `Showing N of at least M (total
unknown: node_budget)` (or `edge_budget`), including when no pagination is needed.
`M` includes the root and counts the admitted prefix; it is a lower bound for the
requested root, depth, type/relationship filters and published generation, not a
count of all application callers. Exactness describes that same recorded-graph
scope and never implies exhaustive source coverage. Paging beyond that prefix
stays partial. To explore more, narrow
`depth`/`types`/`via`, choose another root, or increase the traversal budget within
its maximum. Keep the root, filters, budgets, and published generation unchanged
for stable pages. No wall-clock deadline is used, so cutoffs are deterministic.

Budgets cover traversal work after per-generation graph loading and cache
preparation (JSON parsing, typed-edge normalization, node types and database
metadata). They do not cap that initial load, elapsed time, or total process
memory. These arguments are included in Woods `2.0.0`; check the connected
server's tool schema before sending them to an older installation.

### Traversal explanations

Supporting development versions accept `explain: true` on `dependencies` and
`dependents`. Check the connected schema first; this option is included in Woods
`2.0.0`. Omitted or false keeps the existing compact response.

The additive `explanation` object contains:

- `direction`: `forward` or `reverse`, plus the requested `root` identity.
- `edges`: records keyed by response-local IDs such as `e0`. Every record keeps
  the original **source → target** direction, even during reverse traversal.
  `source` contains its recorded `identifier` and `type`; `target` contains its
  identifier and the unique type when the published graph establishes one.
  `via`, `through`, `through_db`, and `disable_joins` preserve recorded values;
  absent legacy attributes are null (shown as unknown in text), including an
  unrecorded `disable_joins` rather than an invented false value.
- `witnesses`: one shortest breadth-first predecessor per admitted identifier,
  keyed by identifier. Each has `parent`, `edge_id`, `impact` (`root`, `direct`,
  or `transitive`), and `typed_path_complete`. Follow parent references to the
  root to reconstruct one witness; alternative paths are not enumerated.

A target name shared by several types has `type: null`,
`resolution: "ambiguous"`, and sorted `candidate_types`. An unresolved target has
`resolution: "unresolved"` and an empty candidate list. Forward artifacts do not
record target types, so the response cannot choose among candidates. A witness
through an ambiguous or unresolved identity sets `typed_path_complete: false`;
it describes identifier-level reachability, never a uniquely typed path.
A true value means only that identities along this witness have unambiguous
types. It does not establish source-reference coverage or observed execution.
Text labels this `witness types unambiguous=yes/no`; the JSON key and its meaning
remain unchanged. The text label change is included in Woods `2.0.0`.
`types` filters retain the compact traversal's identifier-level semantics: any
registered type can qualify a name, while edge evidence keeps its actual source
owner. Multiple relationship kinds between the same endpoints remain separate.

Direct witnesses establish a recorded root relationship; transitive witnesses
represent inferred downstream reachability through recorded relationships.
Neither establishes observed execution, confidence, call order, or test coverage.

Node pagination retains required ancestor witnesses once, marked `context: true`
when outside the page; returned rows have `context: false`. Context records do
not increase the result-row count. Page evidence retains the witness edges and
other observed relationships among its visible/context endpoints; an empty page
has empty edge/witness maps. Edge IDs are local to this traversal response.

All examined evidence shares the existing edge budget, before `via`/`types`
filtering. Current `reverse_via` buckets allow direct reverse evidence lookup;
legacy recovery charges each reverse candidate and every inspected forward edge.
The shared predecessor forest and emitted records remain bounded by admitted
nodes and inspected edges. Per-generation JSON loading and the cached
O(nodes + variants) ownership/type preparation are outside the walk budget;
explanation mode never flattens all forward edges as per-request preparation.
Partial traversal and pagination metadata retain the budget contract above.

### Conditional Index capabilities

The Ruby server builder contains 16 additional schemas for sessions, pipeline operations, retrieval feedback, temporal snapshots, retained change impact, and Notion sync. They register only when their required collaborators or configuration are wired.

The normal packaged executable does not boot Rails or load application
initializers. It does not wire pipeline-operator or feedback-store collaborators.
`session_trace` needs an in-process configured store supporting `read` and
`sessions`; enabling the Rails middleware alone does not add it to a separate
Index process. `notion_sync` needs the API token and database IDs configured in
that process. These require an explicitly configured custom/embedded builder;
verify `tools/list`. For ordinary application Notion export, use
`bin/rails woods:notion_sync`.

`change_impact` registers with `snapshot_store:` alongside snapshot/history tools,
but compares retained payloads rather than snapshot rows. Pass `from:"gen:1"` and
optional `to:"now"`, or exact typed `focus` identities and optional `at:"now"`.
Selectors are strings: `gen:N`, SHA prefixes or `now`. Mixed range/focus modes fail.
`format` selects `markdown` (default), `json` or `mermaid`; all formats include the
same versioned report in `structuredContent.data`. The tool never saves or shares
reports. Depth is 0..10, with the existing type/via filters and explicit finite
Impact budgets. Focus accepts at most 1000 typed identities over MCP. See the
[impact report contract](https://github.com/lost-in-the/woods/blob/3e36cd22de5b1e484bacb913c4ad827d9f726d80/docs/design/IMPACT_REPORT.md) (source checkout
only, pinned) for coverage and limitations.

Snapshots have a supported packaged path: an existing `woods.sqlite3` is
auto-discovered. `WOODS_SNAPSHOTS=true` enables store construction but does **not**
force JSON: bootstrap prefers SQLite and falls back to JSON only if SQLite is
unavailable or fails. It does not import old JSON history into SQLite. To read
retained JSON history after SQLite becomes available, use a custom builder with
an explicit `Woods::Temporal::JsonSnapshotStore` passed as `snapshot_store:`, or
keep a separate historical reader using that store. See the
[tool wiring table](MCP_TOOL_COOKBOOK.md#conditional-tools--wiring).

For an embedded builder that supplies `operator:`, `pipeline_extract` checks
publication after both full and incremental runs. With the Tasks extension,
a generation-marker or final source-verification failure marks the task
`failed`; it cannot report `completed` merely because extraction returned.
Clients without the extension still receive a background-start acknowledgement,
which does not establish completion. This correction (#584) is included in Woods 2.1; check the loaded server revision. See the
[publication failure recovery](TROUBLESHOOTING.md#extraction-exits-non-zero-after-could-not-publish-generation).

### HTTP transport

Use HTTP only for a deliberate shared or remote deployment. It expands the network boundary and requires authentication, origin restrictions, and TLS termination. Follow [MCP HTTP transport](MCP_HTTP_TRANSPORT.md); do not translate the stdio example into an unauthenticated public listener.


## Console Server

The Console Server launches a Rails process through direct, Docker, or SSH connection configuration. It reads live data and must be treated as a separate security decision.

### Start with the default mode

Console MCP is disabled by default because it reads live application data. Enable the master switch in the Rails initializer only after reviewing the [Console security controls](CONSOLE_MCP_SETUP.md#configuration-options):

```ruby
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_mcp_http_enabled = false # stdio-only
end
```

This explicitly disables HTTP Console while retaining stdio access; no HTTP
token is needed at boot. Existing configurations default to HTTP enabled.
For HTTP deployment, enable the HTTP flag and configure its token, origins
and TLS using the [Console setup guide](CONSOLE_MCP_SETUP.md#option-c-http-rack-middleware).

Without a console connection file, the executable then launches the Rails task directly from its `cwd`:

```json
{
  "mcpServers": {
    "woods-console": {
      "command": "bundle",
      "args": ["exec", "woods-console-mcp"],
      "cwd": "/absolute/path/to/your-rails-app"
    }
  }
}
```

For Docker or SSH, create `~/.woods/console.yml` or set `WOODS_CONSOLE_CONFIG` to a specific YAML file. See [Console MCP setup](CONSOLE_MCP_SETUP.md) for connection examples and safeguards.

### Tool inventory (31 schemas; 9 registered by default)

The packaged default registers these nine tools:

- `console_status`
- `console_schema`
- `console_find`
- `console_count`
- `console_aggregate`
- `console_pluck`
- `console_recent`
- `console_sample`
- `console_association_count`

These tools use structured, read-only operations with validation, limits, blocked-table checks, credential scanning, and response redaction.

### Optional embedded read tools (11 total)

There are 11 with read tools enabled.

Setting `console_embedded_read_tools` explicitly adds:

- `console_sql`
- `console_query`

Both remain subject to Console security policy. SQL validation and rolled-back transactions reduce risk but do not make arbitrary production access a safe default.

### Inventory-only schemas

The source tree contains 31 Console schemas grouped into tiers. The packaged executable registers only the nine default tools or the eleven embedded-read tools above. Tier 2 domain helpers, Tier 3 operational analytics, and `console_eval` do not execute in a supported packaged mode.

This distinction is intentional: schema inventory supports design and compatibility work, while registration defines what an MCP client can actually call.

## Security checklist

Before enabling either server:

- treat the generated index as source code and schema metadata;
- keep project-scoped executable paths pinned to the intended bundle;
- avoid secrets in command arguments or committed client configuration;
- require explicit authorization for Console access and optional read tools;
- use development or purpose-built read-only credentials where possible;
- verify the callable tool list from the connected server, not from source inventory;
- apply authentication, origin controls, and TLS before any HTTP exposure.

Report vulnerabilities privately through [SECURITY.md](../SECURITY.md).

## Troubleshooting order

1. Run `woods:validate` and `woods:stats` in the Rails environment.
2. Run the configured executable manually from the configured `cwd`.
3. Confirm the index path is visible to the process that starts MCP.
4. Reconnect the client and call `woods_status`.
5. Check [Troubleshooting](TROUBLESHOOTING.md) for the exact stderr message.

For agent query behavior after connection, continue to [Agent guide](AGENT_GUIDE.md).

### Explicit retrieval and discovery scope

On a server whose tool schema advertises them, `packages` and `source_paths` narrow
`search` and `codebase_retrieve` before candidate limits. These are per-call
arguments, not configuration settings. Inspect applied scope and completeness;
a narrow graph query can omit relevant cross-boundary dependencies. See the
[scope contract](RETRIEVAL_GUIDE.md#explicit-package-and-source-path-scopes) for
root/nested ownership, path normalization, errors, storage support, and cost.

### Source freshness in status

`woods_status` accepts optional `source_check: "quick"` (default, 250ms scan) or
`"deep"` (five seconds). `index.source_freshness` describes the served generation
as `current`, `drifted` or `unknown`; missing source/key and incomplete capture
never count as current. No Rails initialization or provider call is needed.
**Included in Woods 2.1:** evidence above the serialized-size limit produces
`unavailable` with `source_manifest_too_large` while the code index remains
usable. Follow `inspect_source_limits` and inspect the reported byte counts;
repeating an identical full extraction cannot remove this limitation.
See [source freshness](SOURCE_FRESHNESS.md) for scope, private-key handling and
fresh-process extraction. Existing HEAD/dirty fields remain separate diagnostics.

### Explicit source evidence modes

When advertised by the installed schema, `lookup` and `codebase_retrieve` accept
`evidence: 'compact'` or `'outline'`; omitted/`'full'` preserves existing behavior.
Retrieval uses its original query. Compact lookup accepts optional `query` and an
estimated `budget` (default 2000); full lookup remains complete. `lookup` also
accepts an actual `type` and a `source_sha256` guard for typed, byte-verified
follow-up from an excerpt. Compact modes cannot be combined with metadata-only
lookup controls. Structured provenance stays within the existing closed output
schema's `data` field. Read the [evidence contract](RETRIEVAL_GUIDE.md#compact-published-evidence-and-api-outlines)
before interpreting published line ranges as physical source locations.
