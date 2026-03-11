---
name: codebase-index-setup
description: Guide through CodebaseIndex initial setup — install, configure, extract, verify, and connect MCP servers
---

# CodebaseIndex Setup Guide

Follow these steps to set up CodebaseIndex in a Rails application. Each step builds on the previous one. You can stop after Step 4 and still get value from the MCP servers without embeddings.

---

## Step 1: Install the Gem

Add to your Rails app's `Gemfile`:

```ruby
group :development do
  gem 'codebase_index'
end
```

Install and run the generator:

```bash
bundle install
bundle exec rails generate codebase_index:install
```

**Docker variant:**

```bash
docker compose exec app bundle install
docker compose exec app bundle exec rails generate codebase_index:install
```

The generator creates `config/initializers/codebase_index.rb` with default configuration.

---

## Step 2: Choose a Storage Preset

Pick the preset that matches your environment:

**Local (no external services):** Uses in-memory vectors + SQLite + Ollama embeddings. Works offline, no cloud keys required.

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure_with_preset(:local)
```

**PostgreSQL + OpenAI:** Uses pgvector for vector search + OpenAI embeddings. Requires PostgreSQL with the `pgvector` extension.

```ruby
CodebaseIndex.configure_with_preset(:postgresql)
```

Then install the pgvector extension and run migrations:

```bash
bundle exec rails generate codebase_index:pgvector
bundle exec rails db:migrate
```

**Production (Qdrant + OpenAI):** Uses Qdrant for scalable vector search + OpenAI embeddings. Best for large codebases or shared team deployments.

```ruby
CodebaseIndex.configure_with_preset(:production)
```

**Embedding-free (structural search only):** Skip embeddings entirely — all Index Server tools work without them. Only `codebase_retrieve` requires an embedding provider.

```ruby
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join('tmp/codebase_index')
end
```

---

## Step 3: Run Extraction

Run a full extraction from your Rails app root:

```bash
bundle exec rake codebase_index:extract
```

**Docker variant:**

```bash
docker compose exec app bundle exec rake codebase_index:extract
```

Extraction boots Rails, introspects all models/controllers/services/jobs, builds the dependency graph, enriches units with git metadata, and writes JSON output to `tmp/codebase_index/`.

A typical mid-size Rails app (50–100 models) takes 10–30 seconds.

---

## Step 4: Verify Extraction

Check counts and integrity:

```bash
bundle exec rake codebase_index:stats
bundle exec rake codebase_index:validate
```

Inspect the manifest directly:

```bash
cat tmp/codebase_index/manifest.json
```

A healthy manifest looks like:

```json
{
  "extracted_at": "2026-03-04T12:00:00Z",
  "total_units": 347,
  "counts": {
    "model": 42,
    "controller": 38,
    "service": 91,
    "job": 24
  }
}
```

If `total_units` is 0 or unexpectedly low, check Step 5 of the Diagnosis guide.

---

## Step 5: Configure MCP Servers

Add both servers to your AI tool's MCP configuration.

### Claude Code (`.mcp.json` in your Rails app root)

**Local development (no Docker):**

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "rails-console": {
      "command": "bundle",
      "args": ["exec", "rake", "codebase_index:console"],
      "cwd": "/path/to/your/rails-app"
    }
  }
}
```

**Docker (embedded console — Tier 1 tools only):**

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    },
    "rails-console": {
      "command": "docker",
      "args": [
        "exec", "-i",
        "your_app_web_1",
        "bundle", "exec", "rake", "codebase_index:console"
      ]
    }
  }
}
```

The Index Server always runs on the host reading volume-mounted JSON. Use the host-side path (`./tmp/codebase_index`), not the container path (`/app/tmp/codebase_index`).

### Cursor / Windsurf (`.cursor/mcp.json`)

Same structure as Claude Code above — both tools use the same JSON format.

---

## Step 6: Verify MCP Connection

Test the Index Server responds:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | codebase-index-mcp-start ./tmp/codebase_index
```

You should see a JSON response listing the available tools. If you see an error instead, check that `manifest.json` exists in the path you provided.

Test the Console Server:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bundle exec rake codebase_index:console
```

This should output the tool list and then hang (waiting for more input). Press Ctrl+C to exit. If it exits immediately, run `bundle exec rake codebase_index:console` directly to see the error output.

---

## Next Steps

- Run incremental extraction after code changes: `bundle exec rake codebase_index:incremental`
- Set up CI extraction: see the GitHub Actions example in [MCP_TOOL_COOKBOOK.md](../../MCP_TOOL_COOKBOOK.md)
- Enable Tier 2–4 console tools (diagnostics, SQL, Ruby eval): see [CONSOLE_MCP_SETUP.md](../../CONSOLE_MCP_SETUP.md) Option D
- Enable temporal snapshots for change tracking: set `enable_snapshots: true` in your initializer
