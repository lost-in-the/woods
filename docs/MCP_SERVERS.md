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

### Tools (29 — 14 registered in the packaged default)

The Index Server defines 29 schemas across core and conditional capabilities. The normal packaged executable registers the 14 tools below; the remaining schemas require the specialized wiring described afterward.

| Tool | Use it for |
|---|---|
| `woods_status` | Index health, generation, counts, and retrieval readiness |
| `search` | Discover identifiers by regex, prefix, suffix, source, or metadata |
| `lookup` | Fetch one exact unit with source, metadata, and relationships |
| `dependencies` | Traverse what a unit depends on |
| `dependents` | Traverse what depends on a unit |
| `structure` | Summarize structural relationships around a unit |
| `trace_flow` | Follow a request, job, mail, or other execution flow |
| `framework` | Inspect relevant Rails or installed gem source |
| `recent_changes` | Find indexed units changed recently |
| `graph_analysis` | Analyze paths and neighborhoods in the dependency graph |
| `domain_clusters` | Discover connected domains in the graph |
| `pagerank` | Find structurally central units |
| `reload` | Reload a newly published generation without restarting the client |
| `codebase_retrieve` | Natural-language retrieval; returns a configuration error until embeddings exist |

The server also exposes MCP resources and resource templates for indexed units. Tool descriptions returned by MCP are the parameter-level source of truth; [Agent guide](AGENT_GUIDE.md) explains selection strategy.

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
end
```

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
