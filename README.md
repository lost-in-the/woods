<p align="center">
  <img src="assets/woods-wordmark-white-with-bg.png" width="400" alt="Woods">
</p>

# Woods

**Give AI coding agents a runtime-accurate map of your Rails application.**

Woods boots your Rails app, extracts the behavior Rails assembles at runtime, and serves it to AI tools through the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/). Agents can inspect resolved routes, schema, associations, callbacks, included concerns, dependencies, and execution flows instead of guessing from source files alone.

Woods 2.0 supports Ruby 3.0 or later and Rails 6.0 through 8.x. It connects AI coding tools and agents through MCP.

## What Woods adds

A Rails model rarely lives in one file. Its real behavior can include database schema, generated methods, framework defaults, and concerns loaded from elsewhere:

```ruby
# app/models/order.rb
class Order < ApplicationRecord
  include Auditable
  belongs_to :customer
  after_commit :enqueue_receipt, on: :create
end
```

Woods turns that runtime class into one connected unit with:

- column types, indexes, and foreign keys from the live database;
- associations, validations, scopes, enums, and resolved callbacks;
- source from included concerns, kept beside the owning class;
- callback side effects such as jobs, mailers, and columns written;
- forward dependencies and reverse dependents;
- route, controller, view, job, and service relationships.

The result is a codebase index an agent can query by exact name, pattern, dependency path, graph structure, or natural language.

## Five-minute setup

The default setup provides structural code intelligence. It does not require an embedding provider, vector database, or access to live application records.

### 1. Install Woods

```ruby
# Gemfile
group :development do
  gem "woods", "~> 2.0"
end
```

```bash
bundle install
bin/rails generate woods:install
```

**Do not run the generated migration for a new default installation.** The generator creates an annotated `config/initializers/woods.rb` plus a legacy application migration for `woods_units`, `woods_edges`, and `woods_embeddings`. Woods 2's shipped structural index and storage backends do not use those application tables. Remove the migration before continuing; keep and run it only when deliberately preserving an older/custom integration that uses them.

### 2. Extract and verify the codebase

```bash
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

Extraction must run where Rails can boot. The default index lives at `tmp/woods/`.

### 3. Connect the Index Server

Add this to your MCP client's project configuration. The configuration location varies by client:

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

Restart or reconnect your MCP client, then ask it to call `woods_status`. A ready response with non-zero unit counts confirms the path from Rails extraction to the MCP client.

The Index Server reads the published index from disk. It does not boot Rails or query application records.

> **Using Docker?** Run Rails commands inside the application container. If Woods is installed only there, launch the Index Server through that container too; a host-side server requires a host Ruby bundle and host-visible index. Follow [Docker setup](docs/DOCKER_SETUP.md).

The complete walkthrough, including expected output and first questions to ask, is in [Getting started](docs/GETTING_STARTED.md).

## Choose your path

| Goal | Start here |
|---|---|
| Install Woods yourself | [Getting started](docs/GETTING_STARTED.md) |
| Ask a coding agent to install Woods safely | [Agent setup runbook](docs/AGENT_SETUP.md) |
| Configure an MCP client, Docker, or HTTP | [MCP servers](docs/MCP_SERVERS.md) |
| Teach an agent how to query Woods effectively | [Agent guide](docs/AGENT_GUIDE.md) |
| Add semantic search with OpenAI or local Ollama | [Retrieval guide](docs/RETRIEVAL_GUIDE.md) |
| Query live Rails data through the optional Console Server | [Console MCP setup and security](docs/CONSOLE_MCP_SETUP.md) |
| Keep the index current automatically while coding | [Watch daemon](docs/WATCH_DAEMON.md) |
| Upgrade an existing 1.x installation | [Upgrade to Woods 2.0](docs/UPGRADING_TO_2.md) |
| Diagnose a failure | [Troubleshooting](docs/TROUBLESHOOTING.md) |

## What's new in 2.0

Woods 2.0 is a major release. It changes the index's observable identifier contract, its on-disk layout, the MCP protocol surface, and the failure posture of the tasks that maintain it. The table compares the two lines; the deep detail lives in [CHANGELOG.md](CHANGELOG.md) and the linked references.

| Area | Woods 1.x | Woods 2.0 | On upgrade |
|---|---|---|---|
| Unit identifiers | Namespaces were derived from the first `class` token in a file, so `module Billing; class ChargeJob` indexed as bare `ChargeJob`, and every sibling under one wrapper class collapsed onto the wrapper's identifier | A position-aware nesting parser derives the namespace, and a file on a managed autoload path is named for the constant its path spells (Zeitwerk-governed): `Billing::ChargeJob`, `Domain::Container::Parser`. A type plus identifier still derived from two different files aborts extraction naming both | **Anything holding the old identifiers misses**: saved queries, notes, vectors, exported pages. The remedy is one clean re-index, then re-embed and re-export |
| Index layout | Artifacts were written flat under the index directory, so a reader refreshing mid-run could pair one run's units with another's manifest | Each run publishes an immutable `payloads/gen-<N>/` directory and `generation.json` names the active one, so the single atomic write of that pointer commits the whole payload. Retention keeps three generations (`WOODS_PAYLOAD_RETENTION`) | No re-index. Custom tooling that read root-level `manifest.json`, `dependency_graph.json`, or `<type>/*.json` must follow the pointer |
| MCP protocol | `woods-mcp-start` defaulted `MCP_PROTOCOL_VERSION` to `2024-11-05`, the oldest revision; the HTTP transport minted `Mcp-Session-Id` | `mcp >= 1.2, < 2.0` with protocol revision 2026-07-28: [stateless Streamable HTTP](docs/MCP_HTTP_TRANSPORT.md) by default (`WOODS_MCP_HTTP_STATELESS=0` is a transitional escape hatch), the Tasks extension for pipeline tools, `ttlMs` plus `cacheScope: "private"` cache hints, deterministic sorted tool order, and `server/discover` | Reconnect clients and leave `MCP_PROTOCOL_VERSION` unset. Nothing on disk changes |
| Durable vector stores | An embed run added vectors; nothing removed the ones extraction had stopped producing | pgvector and Qdrant are reconciled against extraction output on full and incremental runs. Deleting more than 30% of the store, or purging into an empty extraction, is refused with an explanation | Back up the store first. A rename-heavy first v2 embed usually needs one authorized run with `WOODS_ALLOW_PURGE=1` after you confirm the deletion |
| Embedding dimensions | A provider/store width mismatch surfaced per row at insert time | `woods:embed` compares the provider's dimension against what the store actually holds before embedding anything, and MCP boot checks the vector dump header, raising `Woods::MCP::DimensionMismatch` with both widths | A latent mismatch surfaces immediately. Rebuild into a store created at the configured width; vectors cannot be converted in place |
| Failure posture | Tasks printed an error count and exited 0, a run whose generation marker failed to publish still reported success, and `woods:incremental` against an empty directory published a near-empty index as the truth | Fail closed: one-shot extraction tasks raise when the generation marker cannot be published, `woods:incremental` and `woods:refresh` refuse an output directory with no baseline index, and `woods:embed`, `woods:embed_incremental`, and `woods:notion_sync` exit 1 when they report errors | CI jobs that were green while failing now fail. Keep a baseline index in the cache, or run a full `woods:extract` first |
| Console Server | Redaction masked output; the SQL gate had comment and dialect blind spots | Redacted columns are refused as query inputs, not only masked on output, including aliases, aggregates, `having`, order and scope keys, and unpaired EAV value columns. `console_sql` is validated once with the live adapter's dialect, and row-lock clauses, writable CTEs, and tables hidden in MySQL executable comments are rejected | Nothing unless Console is enabled. Its callable surface stays the packaged default; see [Console MCP setup](docs/CONSOLE_MCP_SETUP.md#safety-model) |

## Upgrading from 1.x

The full runbook, including backups, rollback, and the verification checklist, is [Upgrade to Woods 2.0](docs/UPGRADING_TO_2.md). The short version:

1. Record the current install: Woods version, output directory, providers, embedding model and dimension, Console settings, enabled exports, and any script that reads the index directly.
2. Back up the output directory and every durable store (pgvector, Qdrant, `dumps/`), plus managed Obsidian and Unblocked destinations.
3. Move the bundle to `gem "woods", "~> 2.0"` with `bundle update woods`, and confirm `mcp` resolves at `>= 1.2, < 2.0`.
4. Review the initializer against the [configuration reference](docs/CONFIGURATION_REFERENCE.md); do not overwrite it with a freshly generated one.
5. Re-index cleanly with `woods:clean`, then `woods:extract`, `woods:validate`, and `woods:stats`. An incremental run is not a valid first v2 extraction.
6. Rebuild what depends on identifiers: `woods:embed`, then each export. Review any refused purge before authorizing it.
7. Reconnect MCP clients, update agent prompts that name a tool inventory, and work through the verification checklist before reopening access.

## Optional Claude Code workflows

Woods itself is MCP-client and model independent. For Claude Code users, the
separately packaged Woods plugin adds guided setup, MCP configuration, and
diagnosis workflows:

```text
/plugin marketplace add lost-in-the/plugins
/plugin install woods-plugin@lost-in-the-plugins
```

Other MCP clients do not need this plugin; follow the human or agent runbooks
linked above and configure either stdio or Streamable HTTP directly.

## Two servers, two trust boundaries

Woods ships two MCP servers. Most users only need the Index Server.

| | Index Server | Console Server |
|---|---|---|
| Purpose | Query pre-extracted code context | Query live Rails models and schema |
| Data source | Files under `tmp/woods/` | A booted Rails process and its database |
| Default tools | 14 | 9 |
| Optional tools | Semantic retrieval activates after embedding; advanced Ruby embeddings can wire more collaborators | `console_sql` and `console_query` raise the total to 11 when explicitly enabled |
| Default posture | Read-only index | Disabled; live-data access requires deliberate setup |

The 14 Index tools cover health, exact lookup, search, dependency traversal, flow tracing, graph analysis, framework source, change recency, and optional semantic retrieval. The Console Server exposes nine supported model/schema tools by default. Nineteen Tier 2/3 Console schemas (9 Tier 2, 10 Tier 3) and `console_eval` exist as source inventory but do not register in any supported mode.

See [MCP servers](docs/MCP_SERVERS.md) for the callable tool lists and client configuration.

## Optional semantic search

Exact search, lookup, graph traversal, and flow tools work after extraction alone. Natural-language retrieval through `codebase_retrieve` also needs embeddings:

```ruby
# config/initializers/woods.rb
Woods.configure_with_preset(:local)
```

The `:local` preset uses SQLite metadata, in-memory vectors persisted under the index, and a local Ollama service. It needs the `sqlite3` gem in the application bundle plus an installed, running Ollama service, but no cloud API key. Pull the default model before the first embed:

```bash
ollama pull nomic-embed-text
```

MySQL/PostgreSQL applications that do not bundle `sqlite3` can use `:shared_filesystem` for local persisted stores instead. PostgreSQL/OpenAI, Qdrant/OpenAI, and shared-filesystem configurations are documented in the [backend matrix](docs/BACKEND_MATRIX.md) and [configuration reference](docs/CONFIGURATION_REFERENCE.md).

For dense Ruby source, add `gem "tokenizers", "~> 0.5"` for exact WordPiece token counting. Without it, Woods uses a character estimate that can over-pack some Ollama chunks.

```bash
bin/rails woods:embed
```

Reconnect the Index Server after the first embed, then check `woods_status` before using `codebase_retrieve`.

## Keeping the index current

Run a full extraction after installation or broad configuration changes:

```bash
bin/rails woods:extract
```

For automatic maintenance during development, run the watcher as a dedicated process:

```bash
bin/rails woods:watch
```

Add it to your development process manager so it starts beside Rails:

```text
# Procfile.dev
web:   bin/rails server
woods: bundle exec rake woods:watch
```

The watcher catches up changes made while it was stopped, batches new file changes, reloads Rails code when safe, and publishes complete generations atomically. The Index Server notices a new generation on its next tool call and refreshes itself. **After the initial extraction, ordinary code changes need no manual re-extraction or MCP restart.**

Changes to boot-captured state, including dependencies, initializers, database configuration, credentials, or schema, make the watcher exit with status 75 so a process supervisor can restart it cleanly. If semantic retrieval is enabled, the watcher keeps structural context current; run `bin/rails woods:embed_incremental` to update vectors.

Without a resident watcher, run `bin/rails woods:incremental` after changes. See [Watch daemon](docs/WATCH_DAEMON.md) for Docker polling, failure behavior, and restart triggers.

## What gets indexed

Woods recognizes the Rails application as a connected system, including:

- models, concerns, controllers, routes, middleware, and engines;
- services, interactors, commands, jobs, mailers, and scheduled work;
- ERB views, Phlex components, ViewComponents, and navigation edges;
- GraphQL types, mutations, resolvers, and fields;
- policies, serializers, decorators, validators, state machines, and events;
- migrations, database views, factories, tests, configuration, and installed framework source.

Read the [extractor reference](docs/EXTRACTOR_REFERENCE.md) for the complete per-type contract and [architecture](docs/ARCHITECTURE.md) for how extraction, storage, retrieval, and MCP fit together.

## Security boundary

Woods extraction reads application code, resolved Rails configuration, and database schema. Treat the generated index as source code: do not publish it unless the source itself may be published.

The optional Console Server has a larger trust boundary because it can read live application data. It is disabled by default and adds table blocking, credential scanning, column redaction, SQL validation, and rolled-back transactions when enabled. Those controls reduce risk; they do not turn production data access into a harmless default. Review [Console MCP security](docs/CONSOLE_MCP_SETUP.md#safety-model) before enabling it.

Report vulnerabilities privately through [SECURITY.md](SECURITY.md).

## Documentation

Use the [documentation index](docs/README.md) to find guides by task or audience. Frequently used references include:

- [Configuration reference](docs/CONFIGURATION_REFERENCE.md)
- [MCP tool cookbook](docs/MCP_TOOL_COOKBOOK.md)
- [FAQ](docs/FAQ.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Upgrade to Woods 2.0](docs/UPGRADING_TO_2.md)

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request. Coding agents working in the source repository should also read [AGENTS.md](https://github.com/lost-in-the/woods/blob/main/AGENTS.md).

## License

Woods is available under the [MIT License](LICENSE.txt).
