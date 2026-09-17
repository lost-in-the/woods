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

`woods-mcp-start` checks that the directory and published manifest exist, then replaces itself with `woods-mcp`. It does not install dependencies or restart a crashed process.

`woods_status.index.woods_version` identifies the last publisher of the served
manifest; `server.version` identifies the running MCP reader. Missing writer
provenance is `null`. See [manifest writer provenance](PUBLISHED_INDEX.md#manifest-writer-provenance).

You can launch the server directly when the client already handles preflight:

```bash
bundle exec woods-mcp ./tmp/woods
```

Keep stdout reserved for MCP protocol messages. Diagnose startup failures from stderr or by running the same command in a terminal.

### Client configuration locations

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

### Initialization guidance

The Index Server supplies a short, client-neutral `instructions` field through
the SDK's `initialize` response and modern `server/discover`. It describes the
status → discovery → inspection → bounded traversal → source-verification
workflow, and lists only the tools actually registered by this server.
Instructions are stable for unchanged tool registration and bounded to 2,048
UTF-8 bytes across supported configurations. Building the text does not probe
providers, extract code, or write configuration.

Registration alone does not establish retrieval readiness: check `woods_status`
before using `codebase_retrieve`, including after reload. The guidance grants
no extraction, configuration-change, or Console authorization. Detailed usage
belongs in the [agent guide](AGENT_GUIDE.md).

This addition is unreleased after `2.0.0.beta2`. The SDK omits `instructions`
when negotiating protocol `2024-11-05`; that behavior is preserved. Older gems,
legacy clients, and clients that do not show server instructions can use the
agent guide or investigation skill. Leave protocol negotiation enabled rather
than pinning a newer version solely to obtain guidance.

### Tools (29 — 14 registered in the packaged default)

The Index Server defines 29 schemas across core and conditional capabilities. The normal packaged executable registers the 14 tools below; the remaining schemas require the specialized wiring described afterward.

| Tool | Use it for |
|---|---|
| `woods_status` | Index health, generation, counts, and retrieval readiness |
| `search` | Discover identifiers by regex, prefix, suffix, source, or metadata |
| `lookup` | Fetch one exact unit with source, metadata, and relationships |
| `dependencies` | Traverse what a unit depends on (`depth`, `types`, `via` narrow; `max_nodes`, `max_edges` budget work; `limit`, `offset` page) |
| `dependents` | Traverse what depends on a unit (`depth`, `types`, `via` narrow; `max_nodes`, `max_edges` budget work; `limit`, `offset` page) |
| `structure` | Summarize structural relationships around a unit |
| `trace_flow` | Follow a request, job, mail, or other execution flow |
| `framework` | Inspect relevant Rails or installed gem source |
| `recent_changes` | Find indexed units changed recently |
| `graph_analysis` | Structural reports: orphans, dead ends, hubs, cycles, bridges, cross-database edges, volatile dependencies, undeclared package edges |
| `domain_clusters` | Discover connected domains in the graph |
| `pagerank` | Find structurally central units |
| `reload` | Reload a newly published generation without restarting the client |
| `codebase_retrieve` | Natural-language retrieval with embeddings or explicit lexical mode over extraction output |

The server also exposes MCP resources and resource templates for indexed units. Tool descriptions returned by MCP are the parameter-level source of truth; [Agent guide](AGENT_GUIDE.md) explains selection strategy.

Structural reads can use a read-only index mount. The `reload` tool is different:
its transactional in-memory retrieval refresh takes the same on-disk writer lock as
extraction and embedding, so the MCP process needs write access to the index
directory. If it cannot acquire or create that lock, reload returns a typed degraded
error and continues serving the previous aligned generation; it never swaps in a
partial or empty replacement. Grant write access for live reloads, or restart the MCP
process after publishing a new embedded index.

### Search completeness

Search responses retain `query`, `result_count`, and `results`; `result_count`
is the number returned, not an estimated total. The additive `completeness`
object describes the requested types, literal filters, and fields in the pinned
generation. This contract is unreleased after `2.0.0.beta2`.

| `reason` | `status` | `has_more` | `total_matches` |
|---|---|---|---|
| `exhausted` | `complete` | `false` | Exact count |
| `result_limit` | `partial` | `true` | `null` (unknown) |
| `scan_budget` or `regex_timeout` | `partial` | `null` (unknown) | `null` (unknown) |

`matched_lower_bound` counts distinct observed `(type, identifier)` matches,
including at most one lookahead match beyond `limit`. A result-limit response
therefore establishes another match; an exactly full page can instead be
complete if the requested domain is exhausted. Deep lookahead shares
`WOODS_SEARCH_MAX_SCAN` with the initial scan and retains round-robin scanning
across types. Search does not count the entire omitted tail or offer pagination.

All partial responses retain `partial: true` and include a narrowing `hint`.
JSON exposes these fields; Markdown, plain text, and Claude formats label the
returned count, stopping reason, known/unknown remainder, and total explicitly.
Narrow `types`, literal `exact_prefix`/`exact_suffix`, or deep `fields` before
using discovery as exhaustive evidence. Completeness applies to this index and
query domain, not to unindexed application code.

Detected missing, unreadable, or corrupt artifacts remain `isError: true` with
`_meta.error_code: "corrupt_artifact"`. Their `_meta.completeness` has
`status: "unknown"`, `reason: "unreadable_or_corrupt_source"`, and `null` for
`has_more`, `total_matches`, and `matched_lower_bound`; no successful empty
result is substituted. Inspect `woods_status` and run `woods:validate`.

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
graph**. Paging beyond that prefix stays partial. To explore more, narrow
`depth`/`types`/`via`, choose another root, or increase the traversal budget within
its maximum. Keep the root, filters, budgets, and published generation unchanged
for stable pages. No wall-clock deadline is used, so cutoffs are deterministic.

Budgets cover traversal work after per-generation graph loading and cache
preparation (JSON parsing, typed-edge normalization, node types and database
metadata). They do not cap that initial load, elapsed time, or total process
memory. These arguments are unreleased in Woods 2.0.0.beta2; check the connected
server's tool schema before sending them to an older installation.

### Conditional Index capabilities

The Ruby server builder contains 15 additional schemas for sessions, pipeline operations, retrieval feedback, temporal snapshots, and Notion sync. They register only when their required collaborators or configuration are wired.

The normal packaged executable does not wire pipeline-operator or feedback-store collaborators. Do not tell users to call those tools after a standard `woods-mcp` launch. Snapshot, session, and Notion capabilities are specialized configurations; document and test the exact embedded server construction when enabling them.

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
