---
name: woods-setup
description: Guide through Woods initial setup — install, configure, extract, verify, and connect MCP servers
---

# Woods Setup Guide

Follow these steps to set up Woods in a Rails application. Each step builds on the previous one. You can stop after Step 4 and still get value from the MCP servers without embeddings.

---

## Version Preflight

Check which Woods version is installed and operate only against it:

```bash
bundle info woods        # installed version + path (once the gem is in the Gemfile)
```

This guide targets **Woods ≥ 2.0.0**. If the installed gem is older, some rake tasks, MCP
tools, or config keys referenced below may not exist — tell the user to update
(`bundle update woods`) rather than running commands the installed version doesn't support.
If a newer release is available on RubyGems, mention it so the user can pick up new features.

---

## Step 1: Install the Gem

Add to your Rails app's `Gemfile`:

```ruby
group :development do
  gem 'woods'
end
```

Install and run the generator:

```bash
bundle install
bundle exec rails generate woods:install
```

**Docker variant:**

```bash
docker compose exec app bundle install
docker compose exec app bundle exec rails generate woods:install
```

The generator creates `config/initializers/woods.rb` with default configuration.

---

## Step 2: Choose a Storage Preset

Pick the preset that matches your environment:

**Local (no external services):** Uses in-memory vectors + SQLite + Ollama embeddings. Works offline, no cloud keys required.

```ruby
# config/initializers/woods.rb
Woods.configure_with_preset(:local)
```

**PostgreSQL + OpenAI:** Uses pgvector for vector search + OpenAI embeddings. Requires PostgreSQL with the `pgvector` extension.

```ruby
Woods.configure_with_preset(:postgresql)
```

Then install the pgvector extension and run migrations:

```bash
bundle exec rails generate woods:pgvector
bundle exec rails db:migrate
```

**Production (Qdrant + OpenAI):** Uses Qdrant for scalable vector search + OpenAI embeddings. Best for large codebases or shared team deployments.

```ruby
Woods.configure_with_preset(:production)
```

**Embedding-free (structural search only):** Skip embeddings entirely — all Index Server tools work without them. Only `codebase_retrieve` requires an embedding provider.

```ruby
Woods.configure do |config|
  config.output_dir = Rails.root.join('tmp/woods')
end
```

---

## Step 3: Run Extraction

Run a full extraction from your Rails app root:

```bash
bundle exec rake woods:extract
```

**Docker variant:**

```bash
docker compose exec app bundle exec rake woods:extract
```

Extraction boots Rails, introspects all models/controllers/services/jobs, builds the dependency graph, enriches units with git metadata, and writes JSON output to `tmp/woods/`.

A typical mid-size Rails app (50–100 models) takes 10–30 seconds.

---

## Step 4: Verify Extraction

Check counts and integrity:

```bash
bundle exec rake woods:stats
bundle exec rake woods:validate
```

Inspect the manifest directly. As of the current release, extraction publishes
into `tmp/woods/payloads/gen-<N>/`, and `generation.json` at the index root
points at the current one — a bare `cat tmp/woods/manifest.json` will miss it
on a fresh install:

```bash
gen=$(jq -r '.payload // empty' tmp/woods/generation.json)
cat "tmp/woods/${gen:-.}/manifest.json"
```

(`${gen:-.}` falls back to the flat root for an index written before payloads
existed — that path still works unchanged.)

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

If `total_units` is 0 or unexpectedly low, check the "Check Extraction Output" step of the Diagnosis guide (`woods-diagnose` skill, Step 2).

---

## Step 5: Configure MCP Servers

Add both servers to your AI tool's MCP configuration.

### Claude Code (`.mcp.json` in your Rails app root)

**Local development (no Docker):**

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "rails-console": {
      "command": "bundle",
      "args": ["exec", "rake", "woods:console"],
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
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    },
    "rails-console": {
      "command": "docker",
      "args": [
        "exec", "-i",
        "your_app_web_1",
        "bundle", "exec", "rake", "woods:console"
      ]
    }
  }
}
```

The Index Server always runs on the host reading volume-mounted JSON. Use the host-side path (`./tmp/woods`), not the container path (`/app/tmp/woods`).

### Cursor / Windsurf (`.cursor/mcp.json`)

Same structure as Claude Code above — both tools use the same JSON format.

---

## Step 6: Verify MCP Connection

Test the Index Server responds:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | woods-mcp-start ./tmp/woods
```

You should see a JSON response listing the available tools. If you see an error instead, check that `manifest.json` exists in the path you provided.

Test the Console Server:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bundle exec rake woods:console
```

This should output the tool list and then hang (waiting for more input). Press Ctrl+C to exit. If it exits immediately, run `bundle exec rake woods:console` directly to see the error output.

---

## Next Steps

- Run incremental extraction after code changes: `bundle exec rake woods:incremental`
- Set up CI extraction: see the GitHub Actions example in [MCP_TOOL_COOKBOOK.md](https://github.com/lost-in-the/woods/blob/main/docs/MCP_TOOL_COOKBOOK.md)
- Unlock `console_sql` / `console_query` (the only tools a config flag can add — Tier 2, Tier 3, and `console_eval` are inventory-only in every mode): set `config.console_embedded_read_tools = true`. See [CONSOLE_MCP_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_MCP_SETUP.md)
- Enable temporal snapshots for change tracking: set `enable_snapshots: true` in your initializer
