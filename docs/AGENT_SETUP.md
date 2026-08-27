# Agent setup runbook

Use this runbook when a coding agent installs or configures Woods 2.0 in an existing Rails repository. The goal is a small, reviewable change and a working structural Index Server. Semantic retrieval and live-data access are separate opt-ins.

## Default decision

Install the structural index only unless the user explicitly asks for another capability.

| Capability | Default | Requires explicit approval when agent-operated |
|---|---:|---|
| Extract Rails code and schema structure | On | No |
| Local or hosted embeddings | Off | Yes: adds a service, credentials, cost, or generated vectors |
| Console MCP | Off | Yes: boots Rails and can read live application data |
| HTTP MCP transport | Off | Yes: expands network exposure |
| Purging or rebuilding durable stores | Off | Yes: can remove Woods-owned data |

## 1. Preflight without changing files

Read the repository's agent instructions first. Then record:

```bash
git status --short --branch
ruby --version
bundle exec rails --version
bundle exec rails runner 'puts Rails.application.class.name'
```

Also determine:

- whether Rails commands run on the host or through Docker Compose;
- which Compose service owns the Rails process, if applicable;
- the database adapter and whether migrations are allowed in this environment;
- whether `woods` already appears in the Gemfile or lockfile;
- whether `config/initializers/woods.rb`, Woods migrations, or Woods tables already exist;
- whether `tmp/woods/` is ignored or intentionally published.

If the worktree contains unrelated changes, preserve them. Do not overwrite an existing initializer or migration without showing the conflict to the user.

## 2. Choose the installation path

Use structural-only setup when the user wants code navigation, runtime Rails structure, dependencies, flows, or blast-radius analysis. Fourteen tools register in the normal packaged launch without an embedding provider.

Discuss semantic retrieval only if the user needs natural-language `codebase_retrieve`. The choice depends on whether they prefer local Ollama or hosted OpenAI and which vector store fits their environment. See [Backend matrix](BACKEND_MATRIX.md).

Do not infer permission to configure Console MCP from a request to “set up Woods” or “set up MCP.” The Index Server reads generated code context; the Console Server can read live data.

## 3. Install on a branch

Create or switch to the branch requested by the repository owner. Add only the development dependency:

```ruby
# Gemfile
group :development do
  gem "woods", "~> 2.0"
end
```

Run the repository's normal dependency command:

```bash
bundle install
bundle exec ruby -rwoods/version -e 'puts Woods::VERSION'
```

Do not broadly update unrelated gems. Review the Gemfile and lockfile diff before continuing.

## 4. Generate, inspect, and migrate

```bash
bin/rails generate woods:install
git diff -- config/initializers/woods.rb db/migrate
```

Before migrating, confirm that the generated migration creates only Woods-owned tables and that its names do not conflict with an earlier installation:

- `woods_units`
- `woods_edges`
- `woods_embeddings`

Run the migration only in an authorized development or test database:

```bash
bin/rails db:migrate
```

Follow repository policy for containers and schema changes. Never run a production migration as an incidental setup step.

## 5. Extract and validate

Use the same execution environment and boot variables the Rails app normally needs:

```bash
bin/rails woods:extract
bin/rails woods:validate
bin/rails woods:stats
```

If extraction fails, reproduce Rails boot and eager loading outside Woods before changing configuration:

```bash
bin/rails runner 'puts Rails.application.class.name'
bin/rails runner 'Rails.application.eager_load!; puts "eager load ok"'
```

Fix one root cause at a time. Do not suppress an application boot error to make extraction appear successful.

## 6. Configure the Index MCP client

Prefer a project-scoped configuration so the executable, bundle, and index all belong to the same repository:

```json
{
  "mcpServers": {
    "woods": {
      "command": "bundle",
      "args": ["exec", "woods-mcp-start", "./tmp/woods"],
      "cwd": "/absolute/path/to/the-rails-app"
    }
  }
}
```

For Docker, extraction usually runs inside the Rails container while the stdio MCP process runs on the host. Resolve `./tmp/woods` to the host-visible side of the mounted volume; do not put a container-only path in a host client configuration.

Reconnect the client and call `woods_status`. Confirm a current generation and non-zero unit counts before claiming setup works.

## 7. Verify useful behavior

Use a class known to exist in the application:

1. Call `search` to obtain its exact identifier.
2. Call `lookup` to confirm source and metadata are present.
3. Call `dependents` with depth 1 or 2 to confirm graph edges are queryable.

If `codebase_retrieve` reports that semantic search is disabled, that is expected for structural-only setup. Do not configure credentials merely to remove the message.

## Stop and ask before

Get explicit user approval before:

- enabling Console MCP or granting access to a live database;
- enabling `console_embedded_read_tools`, `console_sql`, or `console_query`;
- adding an API key, hosted embedding provider, Qdrant, pgvector, or Ollama service;
- exposing MCP over HTTP, selecting bind addresses, or configuring bearer tokens;
- overriding a purge guard or deleting/rebuilding Woods durable data;
- overwriting an existing Woods initializer, migration, or MCP configuration;
- changing production or shared infrastructure.

## Handoff report

Return a concise report the owner can verify:

```text
Woods version:
Branch:

Files changed:
- Gemfile / lockfile:
- initializer:
- migration/schema:
- MCP client configuration:

Commands run:
- install:
- migrate:
- extract:
- validate/stats:

Verified capabilities:
- Index Server connected: yes/no
- woods_status current: yes/no
- search/lookup/dependents checked: yes/no
- semantic retrieval: disabled/enabled (provider)
- Console MCP: disabled/enabled (authorization)

Follow-up or unresolved risk:
```

Never report a capability as enabled solely because its schema exists in source. Report what the packaged executable actually registered and what you called successfully.

## Copyable prompt for an installation agent

> Install Woods 2.x in this Rails repository using `docs/AGENT_SETUP.md`. Start with read-only preflight and preserve unrelated changes. Default to the structural Index Server; do not enable embeddings, Console MCP, HTTP transport, secrets, or purge overrides without asking me. Inspect generated files before migrating, run extraction and validation in the app's normal execution environment, configure a project-scoped MCP server with a host-visible index path, and verify `woods_status`, `search`, `lookup`, and `dependents`. Finish with the runbook's handoff report.

## Related guides

- [Getting started](GETTING_STARTED.md) for the human walkthrough.
- [MCP servers](MCP_SERVERS.md) for client-specific configuration and server boundaries.
- [Upgrade to Woods 2.0](UPGRADING_TO_2.md) for an existing 1.x installation.
- [Troubleshooting](TROUBLESHOOTING.md) for extraction and connection failures.
