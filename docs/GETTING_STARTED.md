# Getting started with Woods 2.0

This guide takes a Rails application from no Woods installation to a validated index that an MCP client can query. The default path is structural only: it does not require OpenAI, Ollama, a vector database, or access to application records.

## Before you begin

Woods 2.0 requires Ruby 3.0 or later, Rails 6.0 through 8.x, a Rails environment that can boot and connect to its database, and Bundler. An MCP-capable client is only needed when an agent will query the result.

The install generator adds an initializer and a migration. The migration creates Woods-owned metadata, edge, and embedding tables. Extraction boots Rails and writes a generated index under `tmp/woods/` by default; it does not read rows from your application's business tables.

If an agent will perform the installation, use the safety and handoff checklist in [Agent setup](AGENT_SETUP.md).

## 1. Install the gem

Add Woods to the development group:

```ruby
# Gemfile
group :development do
  gem "woods", "~> 2.0"
end
```

Then install and confirm the resolved version:

```bash
bundle install
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
```

If your application runs through Docker Compose, run Rails and Bundler commands inside its application service. See [Docker setup](DOCKER_SETUP.md) before configuring MCP paths.

## 2. Generate and review configuration

```bash
bin/rails generate woods:install
```

Review the generated files:

- `config/initializers/woods.rb` documents supported configuration;
- `db/migrate/*_create_woods_tables.rb` is a legacy application migration for `woods_units`, `woods_edges`, and `woods_embeddings`.

**For a new default installation, do not run that migration.** Woods 2's shipped structural index and storage backends do not read or write those application tables. Remove it before the next Rails boot. Keep and run it only when deliberately preserving an older/custom integration that uses the tables; first check for name conflicts and obtain normal migration approval.

The generated initializer defaults are enough for structural extraction. Do not choose a storage preset or configure an embedding provider unless you want semantic search.

## 3. Extract the application

```bash
bin/rails woods:extract
```

Woods boots and eager-loads the Rails application, runs its extractors, builds dependency edges, and publishes one complete generation under `tmp/woods/`. A reader stays on the previous complete generation until the new one is published.

If Rails only boots with environment variables, provide the same variables here. Do not work around a boot failure inside Woods configuration. First confirm that the application can boot and eager-load with the same environment:

```bash
bin/rails runner 'puts Rails.application.class.name'
bin/rails runner 'Rails.application.eager_load!; puts "eager load ok"'
```

## 4. Validate and inspect the index

Use the Woods tasks rather than depending on internal filenames:

```bash
bin/rails woods:validate
bin/rails woods:stats
```

Validation should finish successfully. Statistics should report non-zero units for the types your application contains. The exact distribution varies by application.

The generated directory is disposable build output. Add `tmp/woods/` to `.gitignore` unless your team deliberately publishes it as an artifact.

## 5. Connect the Index Server

The Index Server reads the generated index. It does not boot Rails and does not query application records.

For a project-scoped stdio MCP client, add the equivalent server entry at the application root (for clients that support `.mcp.json`, use this shape):

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

Use an absolute `cwd`. It ensures Bundler resolves the application's Woods version and makes the relative index path unambiguous. Reconnect or restart the MCP client after changing its configuration.

For client-specific configuration locations, Docker, direct `woods-mcp`, and HTTP transport, use [MCP servers](MCP_SERVERS.md).

## 6. Verify from the client

Ask the client to call these tools in order:

1. `woods_status` — confirm the index path, generation, unit counts, and retrieval status.
2. `search` with a known class name — discover its exact Woods identifier.
3. `lookup` with that identifier — inspect its runtime source, metadata, and relationships.
4. `dependents` with that identifier — see what may be affected by a change.

For example:

> Use Woods to find `Order`, inspect its resolved callbacks and associations, and list the first two levels of code that depend on it. Cite the Woods identifiers you used.

The Index schema inventory totals 29 tools. Fourteen register in a normal packaged launch; `codebase_retrieve` is among them but returns a configuration error until embeddings are enabled. The other structural tools work immediately. See [Agent guide](AGENT_GUIDE.md) for a reliable query workflow.

## Optional next steps

### Add semantic search

Structural search, exact lookup, dependency traversal, graph analysis, and flow tracing do not need embeddings. Add embeddings only when agents need natural-language retrieval.

The local preset uses SQLite metadata, persisted in-memory vectors, and a local Ollama service. Add `gem "sqlite3"` to the application bundle if it is not already present. MySQL/PostgreSQL applications that do not want that dependency can use the `:shared_filesystem` preset instead; it still uses Ollama but persists all stores beneath the Woods output directory.

```ruby
# config/initializers/woods.rb
Woods.configure_with_preset(:local)
```

Install and start Ollama, then pull the default model and build embeddings:

```bash
ollama pull nomic-embed-text
bin/rails woods:embed
```

For dense Ruby source, add `gem "tokenizers", "~> 0.5"` for exact WordPiece token counting. Without it, Woods falls back to character-based estimation, which can over-pack some Ollama chunks.

Reconnect the MCP server and check `woods_status`. For OpenAI, pgvector, Qdrant, model dimensions, and provider changes, read the [Retrieval guide](RETRIEVAL_GUIDE.md) and [Backend matrix](BACKEND_MATRIX.md).

### Keep the index current

For automatic maintenance, keep a watcher running beside the Rails development process:

```bash
bin/rails woods:watch
```

```text
# Procfile.dev
web:   bin/rails server
woods: bundle exec rake woods:watch
```

On startup it reconciles changes made since the last successful generation. While running it batches file events, reloads Rails code when safe, extracts affected units, and publishes atomically. The Index Server detects the new generation on its next call and reloads automatically. After the initial extraction, ordinary code edits need no manual extraction or MCP restart.

When dependencies, initializers, database configuration, credentials, or schema change, Rails cannot safely reload all captured state. The watcher records a degraded reason and exits with status 75 so the process manager can restart it. Docker bind mounts may require polling; follow [Watch daemon](WATCH_DAEMON.md).

The watcher maintains the structural index. If semantic retrieval is enabled, also run `bin/rails woods:embed_incremental` to update vectors. Without a resident watcher, run `bin/rails woods:incremental` after changes. Use a full `woods:extract` after major upgrades or when validation reports drift. CI and shared-artifact patterns are covered in [Incremental extraction](INCREMENTAL_EXTRACTION.md).

### Enable the Console Server

The Console Server is separate from the Index Server. It boots Rails and can read live model data. Do not enable it merely to inspect code structure.

If live-data queries are necessary, review its allowlists, blocked tables, credential scanning, redaction, SQL validation, and environment boundary in [Console MCP setup](CONSOLE_MCP_SETUP.md). The default surface is nine tools; `console_sql` and `console_query` require an explicit read-tools opt-in.

## First-run problems

| Symptom | Check first | Continue with |
|---|---|---|
| Bundler cannot resolve Woods | Ruby/Rails requirements and the lockfile's selected gem version | [Upgrade guide](UPGRADING_TO_2.md) |
| Generator reports existing files | Diff the existing initializer and migration; do not overwrite blindly | [Configuration reference](CONFIGURATION_REFERENCE.md) |
| Rails fails during extraction | Boot and eager-load Rails with the same environment variables | [Troubleshooting](TROUBLESHOOTING.md) |
| Validation reports missing or stale units | Run a full extraction, then validate again | [Incremental extraction](INCREMENTAL_EXTRACTION.md) |
| MCP reports no index or zero units | Confirm `cwd`, the host-visible `tmp/woods` path, and `woods:stats` output | [MCP servers](MCP_SERVERS.md) |
| `codebase_retrieve` says it is disabled | Configure an embedding provider and run `woods:embed`, or use `search` | [Retrieval guide](RETRIEVAL_GUIDE.md) |
| Docker extraction succeeds but MCP cannot see it | Translate the container output path to its host-mounted path | [Docker setup](DOCKER_SETUP.md) |

## Where to go next

- [Agent guide](AGENT_GUIDE.md): teach an agent to use the index effectively.
- [MCP servers](MCP_SERVERS.md): client configuration and exact callable surfaces.
- [Configuration reference](CONFIGURATION_REFERENCE.md): supported settings and defaults.
- [Upgrade to Woods 2.0](UPGRADING_TO_2.md): migrate an existing 1.x installation.
- [Troubleshooting](TROUBLESHOOTING.md): diagnose extraction, storage, MCP, and Docker failures.
