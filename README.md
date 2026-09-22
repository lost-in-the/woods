<p align="center">
  <img src="assets/woods-wordmark-white-with-bg.png" width="400" alt="Woods">
</p>

# Woods

**Give coding agents the Rails context that source files alone leave out.**

[![Gem Version](https://img.shields.io/gem/v/woods)](https://rubygems.org/gems/woods)
[![CI](https://github.com/lost-in-the/woods/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/lost-in-the/woods/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

Woods boots your Rails application, extracts its resolved structure, and publishes an index that coding agents can query through the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/). It brings together database schema, associations, callbacks, concerns, routes, and source code so an agent can inspect how Rails assembles your application.

Supports **Ruby 3.0+ and Rails 6.0–8.x**, using a Ruby version supported by your Rails release. The application must boot and connect to its database. Structural queries need no embedding provider or vector database.

[Get started](#five-minute-setup) · [Documentation](docs/README.md) · [Agent setup](docs/AGENT_SETUP.md) · [Upgrade from 1.x](docs/UPGRADING_TO_2.md)

## What Woods adds

Consider a model whose behavior is spread across Rails, the database, and a concern:

```ruby
class Order < ApplicationRecord
  include Auditable
  belongs_to :customer
  after_commit :enqueue_receipt, on: :create
end
```

Woods can give an agent one unit containing its columns and indexes, association metadata, resolved callbacks, and included concern source. Recorded relationships connect that unit to other parts of the application.

An agent can then ask:

> Find the Order model, inspect its callbacks and associations, and show its recorded dependents. Cite the indexed evidence and check source code for callers the graph may miss.

Models are one part of the index: Woods also extracts controllers, routes, jobs, mailers, views, components, GraphQL types, service objects, tests, and more. See the [extractor reference](docs/EXTRACTOR_REFERENCE.md) for coverage and the [agent guide](docs/AGENT_GUIDE.md) for query examples.

## Five-minute setup

For agent-led setup, use the [agent installation option](#let-an-agent-install-it) and its runbook. For a new manual installation, follow the steps below.

**Already using Woods?** If you are upgrading from 1.x, follow the [upgrade guide](docs/UPGRADING_TO_2.md). For an existing 2.x installation, go directly to [retrieval modes](#retrieval-with-or-without-embeddings), [MCP configuration](docs/MCP_SERVERS.md), or the [configuration reference](docs/CONFIGURATION_REFERENCE.md). Preserve your initializer, index path, provider settings, and other client entries. Changing only the MCP launch configuration or retrieval mode does not require rerunning the installer or rebuilding the structural index.

Run installation and extraction commands from your Rails application root in its normal development environment. **Using Docker?** Follow [Docker setup](docs/DOCKER_SETUP.md) first: run those commands inside the application container and use paths visible to the process that runs MCP.

### 1. Install and configure

These steps are for **Woods 2.x**. Choose a published 2.x version from the release information below and confirm it on [RubyGems](https://rubygems.org/gems/woods/versions). If only prereleases are available, use an exact prerelease pin; `~> 2.0` will not select one. Follow the chosen version's tag documentation rather than assuming every feature on `main` is published. If you choose 1.x, use its tag documentation instead of this quickstart.

<details>
<summary>Release information and Gemfile version constraints</summary>

<!-- release-state:version-banner -->
> **This tree documents version 2.0.0.** It is a major update from 1.x: read [what changed and how to upgrade](docs/UPGRADING_TO_2.md) before updating. The full history is in the [CHANGELOG](CHANGELOG.md).
>
> `main` is the development branch and can run ahead of the latest published gem. The gem badge above shows the latest published version; documentation for a published version lives on its tag.
>
> ### Version: this tree declares prerelease 2.0.0.beta4; `main` documents 2.0.0
>
> | Line | Version | Documentation |
> |---|---|---|
> | Documented here | **2.0.0**, unreleased | this README and the [documentation index](docs/README.md) |
> | Declared prerelease | **2.0.0.beta4** | [the v2.0.0.beta4 tag](https://github.com/lost-in-the/woods/tree/v2.0.0.beta4) |
> | Latest published gem | **1.6.2** | [the v1.6.2 tag](https://github.com/lost-in-the/woods/tree/v1.6.2) |
>
> RubyGems treats 2.0.0.beta4 as a prerelease, so `gem "woods", "~> 2.0"` does not resolve it. Once published, install it explicitly with `gem "woods", "2.0.0.beta4"`. The released constraint stays `gem "woods", "~> 1.6"`.
<!-- release-state:end -->

</details>

Expand the release information above, then add its appropriate `gem "woods", …` declaration to your Gemfile's `:development` group and run:

```bash
bundle install
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
bin/rails generate woods:install
```

**For a new default installation, remove the generated `db/migrate/*_create_woods_tables.rb` migration without running it.** Those legacy application tables are unused by the shipped index and storage backends. Keep the generated `config/initializers/woods.rb`; its defaults are sufficient. Only retain the migration for a deliberate older/custom integration. See [Getting started](docs/GETTING_STARTED.md#2-generate-and-review-configuration).

### 2. Extract and validate

```bash
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

Run these where your Rails application can boot. The default output is `tmp/woods/`; keep this generated directory out of source control.

### 3. Connect your MCP client

Adapt this example to your MCP client's project configuration format, using your application path and preserving other server entries. See [client configuration locations](docs/MCP_SERVERS.md#client-configuration-locations) for guidance:

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

Reconnect the client and ask it to call `woods_status`. Confirm the index path and non-zero unit counts. Then use `search` to discover a known class and `lookup` with its identifier **and type** to inspect it.

The Index Server reads the published index without booting Rails or querying application records. See [MCP servers](docs/MCP_SERVERS.md) for client-specific configuration and HTTP transport.

If Woods is installed only inside Docker, launch MCP through that container too. Host-side launch needs a host bundle and a host-visible index; see the [Docker process and path rule](docs/MCP_SERVERS.md#docker-process-and-path-rule).

## Retrieval: with or without embeddings

Exact lookup, pattern search, and graph queries work immediately after extraction. For ranked retrieval through `codebase_retrieve`, choose a mode:

| Mode | Setup | What it searches |
|---|---|---|
| **Lexical** | Set `WOODS_RETRIEVAL_MODE=lexical` in the MCP process environment and restart the server | Published extraction units, ranked by field-aware keyword matching; no provider or embeddings |
| **Semantic** (default mode) | Configure a local or hosted embedding provider, then run `bin/rails woods:embed` | Embedded code context, ranked by semantic similarity |

For the stdio configuration above, add `"env": {"WOODS_RETRIEVAL_MODE": "lexical"}` inside the `woods` server entry to choose lexical mode. Confirm the active retriever with `woods_status`.

To switch back to semantic retrieval, remove the lexical environment override or set `WOODS_RETRIEVAL_MODE=semantic`, configure the provider and embedding artifacts, then restart the MCP server and verify `woods_status`. Switching to lexical does not delete existing vectors or provider configuration.

The [lexical guide](docs/RETRIEVAL_GUIDE.md#embedding-free-lexical-retrieval) and [semantic setup](docs/RETRIEVAL_GUIDE.md#configuring-retrieval) cover configuration, ranking, and response budgets. Lexical matching depends on shared vocabulary; semantic mode requires the configured provider and embedding artifacts.

## Keeping the index current

Run a watcher alongside your development processes:

```bash
bin/rails woods:watch
```

It catches up on changes, publishes complete generations, and lets the Index Server refresh on later tool calls. Use a process supervisor for changes that require the watcher to restart. Without a watcher, run `bin/rails woods:incremental` after edits or `bin/rails woods:extract` for a full rebuild.

Incremental cost depends on the affected code and relationships; broad changes can cost as much as a full extraction. Semantic embeddings have a separate update step. See [Watch daemon](docs/WATCH_DAEMON.md), [incremental extraction](docs/INCREMENTAL_EXTRACTION.md), and [source freshness](docs/SOURCE_FRESHNESS.md).

## Two servers, two trust boundaries

| | Index Server | Console Server |
|---|---|---|
| Purpose | Inspect extracted code context | Query live Rails models and schema |
| Reads | Published index files | A booted application and its database |
| Packaged tools | 14; retrieval usable when configured | 9; 11 with embedded read tools enabled |
| Setup | The workflow above | Optional, disabled by default |

Extraction itself boots and eager-loads your application, so its boot-time behavior still runs. Treat the generated index as confidential application source. Enabling hosted embeddings sends the embedded content to that provider. MCP responses also contain application source, which your client may send to its model provider even when Woods uses lexical retrieval or local embeddings.

The optional Console Server can access live data. Review its [setup and security model](docs/CONSOLE_MCP_SETUP.md) before enabling it. Report vulnerabilities privately through [SECURITY.md](SECURITY.md).

## What the index can and cannot establish

- **It is a snapshot.** Check freshness against your working tree before relying on it for a change.
- **Relationships are recorded evidence, not a complete call graph.** Arbitrary method-body constant references are not exhaustively indexed. No recorded dependents does not prove that a class has no callers or is safe to delete.
- **A traced flow is not proof of execution.** Follow the tool's evidence and limits, and verify behavior in the application when it matters.

Use Woods to locate and connect evidence, then confirm the relevant source and tests. The [agent guide](docs/AGENT_GUIDE.md) describes this workflow.

## Let an agent install it

Use the [agent setup runbook](docs/AGENT_SETUP.md) for a copyable installation prompt and verification checklist. Woods works with MCP-capable clients independently of a specific model or editor.

Claude Code users can optionally install the companion workflows:

```text
/plugin marketplace add lost-in-the/plugins
/plugin install woods-plugin@lost-in-the-plugins
```

The plugin guides installation, MCP configuration, investigation, repository agent setup, and diagnosis. It is distributed separately from the gem.

## Documentation

| Task | Guide |
|---|---|
| Install and verify | [Getting started](docs/GETTING_STARTED.md) |
| Configure clients, Docker, or HTTP | [MCP servers](docs/MCP_SERVERS.md) |
| Query effectively | [Agent guide](docs/AGENT_GUIDE.md) and [tool cookbook](docs/MCP_TOOL_COOKBOOK.md) |
| Configure Woods | [Configuration reference](docs/CONFIGURATION_REFERENCE.md) |
| Choose retrieval and storage | [Retrieval guide](docs/RETRIEVAL_GUIDE.md) and [backend matrix](docs/BACKEND_MATRIX.md) |
| Upgrade from 1.x | [Upgrade guide](docs/UPGRADING_TO_2.md) |
| Diagnose a failure | [Troubleshooting](docs/TROUBLESHOOTING.md) |

See the [documentation index](docs/README.md) for all guides and canonical reference pages.

## Contributing

Use [GitHub issues](https://github.com/lost-in-the/woods/issues) for bugs and feature requests. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request; coding agents should also read [AGENTS.md](https://github.com/lost-in-the/woods/blob/main/AGENTS.md).

## License

[MIT](LICENSE.txt).
