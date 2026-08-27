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
bin/rails db:migrate
```

The generator creates an annotated `config/initializers/woods.rb` and a migration for Woods-owned tables. Review both files before committing them.

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

> **Using Docker?** Run the Rails commands inside the app container, but keep the Index Server on the host and point it at the host-visible volume path. Follow [Docker setup](docs/DOCKER_SETUP.md).

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
| Keep the index current while code changes | [Incremental extraction](docs/INCREMENTAL_EXTRACTION.md) or [watch daemon](docs/WATCH_DAEMON.md) |
| Upgrade an existing 1.x installation | [Upgrade to Woods 2.0](docs/UPGRADING_TO_2.md) |
| Diagnose a failure | [Troubleshooting](docs/TROUBLESHOOTING.md) |

## Two servers, two trust boundaries

Woods ships two MCP servers. Most users only need the Index Server.

| | Index Server | Console Server |
|---|---|---|
| Purpose | Query pre-extracted code context | Query live Rails models and schema |
| Data source | Files under `tmp/woods/` | A booted Rails process and its database |
| Default tools | 14 | 9 |
| Optional tools | Semantic retrieval activates after embedding; advanced Ruby embeddings can wire more collaborators | `console_sql` and `console_query` raise the total to 11 when explicitly enabled |
| Default posture | Read-only index | Disabled; live-data access requires deliberate setup |

The 14 Index tools cover health, exact lookup, search, dependency traversal, flow tracing, graph analysis, framework source, change recency, and optional semantic retrieval. The Console Server exposes nine supported model/schema tools by default. Twenty Tier 2/3 Console schemas and `console_eval` exist as source inventory but do not register in any supported mode.

See [MCP servers](docs/MCP_SERVERS.md) for the callable tool lists and client configuration.

## Optional semantic search

Exact search, lookup, graph traversal, and flow tools work after extraction alone. Natural-language retrieval through `codebase_retrieve` also needs embeddings:

```ruby
# config/initializers/woods.rb
Woods.configure_with_preset(:local)
```

The `:local` preset uses SQLite metadata, in-memory vectors persisted under the index, and a local Ollama service. It needs no cloud API key, but Ollama must be installed and running. PostgreSQL/OpenAI, Qdrant/OpenAI, and shared-filesystem configurations are documented in the [backend matrix](docs/BACKEND_MATRIX.md) and [configuration reference](docs/CONFIGURATION_REFERENCE.md).

```bash
bin/rails woods:embed
```

Reconnect the Index Server after the first embed, then check `woods_status` before using `codebase_retrieve`.

## Keeping the index current

Run a full extraction after installation or broad configuration changes:

```bash
bin/rails woods:extract
```

For ordinary code changes, choose one maintenance path:

```bash
# Update paths changed since the previous extraction
bin/rails woods:incremental

# Or run a resident process that batches changes
bin/rails woods:watch
```

Woods publishes complete generations atomically. Readers stay on the previous complete generation until the next one is ready.

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
