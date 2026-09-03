<p align="center">
  <img src="assets/woods-wordmark-white-with-bg.png" width="400" alt="Woods">
</p>

# Woods

**Give AI coding agents a runtime-accurate map of your Rails application.**

[![Gem Version](https://img.shields.io/gem/v/woods)](https://rubygems.org/gems/woods)
[![CI](https://github.com/lost-in-the/woods/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/lost-in-the/woods/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

> **Version 2.0.0 is the current release** — a major update from 1.x that changes index identifiers, the publication layout, and the MCP surface. Read [what changed and how to upgrade](docs/UPGRADING_TO_2.md) before updating from 1.x; the full history is in the [CHANGELOG](CHANGELOG.md).
>
> `main` is the development branch and can run ahead of the latest published gem. Documentation matching a specific release lives on its tag ([v2.0.0](https://github.com/lost-in-the/woods/tree/v2.0.0)); the gem badge above always shows the latest published version.

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

Still weighing it? [Why Woods](docs/WHY_WOODS.md) makes the case against grep, cloud indexers, and IDE language servers.

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

## Let an agent install it

Woods is built to be agent-operated, and the fastest path is handing installation to the coding agent that will use it. Claude Code users can install the distributed skills once — they trigger on install, upgrade, configuration, investigation, and diagnosis on their own:

```bash
/plugin marketplace add lost-in-the/plugins
/plugin install woods-plugin@lost-in-the-plugins
```

With any coding agent (no plugin needed), paste this into a session opened at your Rails app's root:

```text
Install or upgrade the woods gem in this Rails application by following
https://github.com/lost-in-the/woods/blob/main/docs/AGENT_SETUP.md.
Structural setup only: add the gem to the development group, run the
installer, extract and validate the index, and register the Index MCP
server for this app. Do not run the generated legacy migration, and do
not add embedding providers, vector databases, Console/live-data access,
or secrets without asking me first. If woods 1.x is already installed,
follow the upgrade runbook in docs/UPGRADING_TO_2.md instead and plan a
clean re-index. Finish by reporting the installed version, files
changed, commands run, and one verified woods_status call through the
registered MCP server.
```

The runbook holds the agent to the same guardrails the skills enforce: a version preflight, minimal diffs, and explicit approval before anything beyond the structural index. Prefer doing it by hand? The five-minute setup above is the same procedure as commands.

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

## Upgrading from 1.x

Woods 2.0 is a major release: identifiers, the on-disk layout, the MCP surface, and task failure posture all changed. [Upgrade to Woods 2.0](docs/UPGRADING_TO_2.md) holds the full what-changed table, the step-by-step runbook with backups and rollback, and an agent-operated upgrade prompt.

## Optional Claude Code workflows

Woods itself is MCP-client and model independent. The separately packaged Woods plugin (install commands under [Let an agent install it](#let-an-agent-install-it)) gives Claude Code five guided skills: setup and upgrade, MCP configuration, index-driven investigation, repository agent enablement, and diagnosis. Other MCP clients do not need it; follow the human or agent runbooks linked above and configure either stdio or Streamable HTTP directly.

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

Read the [extractor reference](docs/EXTRACTOR_REFERENCE.md) for the complete per-type contract and [internals](docs/INTERNALS.md) for how extraction, storage, retrieval, and MCP fit together.

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
