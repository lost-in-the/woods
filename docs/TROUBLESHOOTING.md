# Troubleshooting CodebaseIndex

This guide covers the most common problems encountered when installing, extracting, and using CodebaseIndex. Each section follows the pattern: **symptom → cause → fix**.

---

## Extraction Problems

### Extraction produces empty or incomplete output

**Symptom:** Running `rake codebase_index:extract` completes without errors but produces fewer units than expected, or only some model types appear.

**Cause:** `eager_load!` failed silently partway through loading your application. Zeitwerk processes directories alphabetically — if a directory early in the alphabet (e.g., `app/graphql/`) fails to load due to a missing gem, Zeitwerk aborts that pass and never reaches `app/models/`. CodebaseIndex detects this and falls back to per-directory loading, but some units may still be missing.

**Fix:**

1. Check for `NameError` or `LoadError` in the extraction output:

```bash
bundle exec rake codebase_index:extract 2>&1 | grep -i "error\|uninitialized"
```

2. Either install the missing gem(s) referenced in the error, or exclude the problem directory from eager loading:

```ruby
# config/application.rb
config.eager_load_paths -= [Rails.root.join('app/graphql')]
```

3. Re-run extraction after resolving the load issue.

---

### Extraction fails with "Cannot find Rails" or "uninitialized constant"

**Symptom:** Running a rake task fails immediately with `NameError: uninitialized constant Rails` or a similar error about ActiveRecord, ApplicationRecord, or other Rails constants.

**Cause:** Extraction requires a booted Rails environment. CodebaseIndex uses runtime introspection (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs) — these APIs do not exist outside a running Rails app.

**Fix:** Always run extraction rake tasks inside your Rails app:

```bash
# Correct — run from Rails app root
bundle exec rake codebase_index:extract

# Docker — run inside container
docker compose exec app bundle exec rake codebase_index:extract
```

CodebaseIndex cannot extract from source files alone. It is not a static analysis tool.

---

### Extraction is very slow

**Symptom:** A full extraction takes several minutes instead of 10-30 seconds.

**Cause:** Two common causes — a very large codebase (500+ models), or framework source extraction enabled on an app with many gems.

**Fix:**

Disable framework source extraction if you don't need Rails/gem internals:

```ruby
config.include_framework_sources = false
```

For subsequent runs, use incremental mode instead of full extraction:

```bash
bundle exec rake codebase_index:incremental
```

Incremental extraction only re-extracts files that changed since the last run. It skips unchanged units and is typically 5-10× faster.

---

### Some extractor types are not appearing in output

**Symptom:** You expect state machines, events, decorators, or other unit types but they don't appear in the output directory.

**Cause:** All 34 extractors always run during extraction — there is no opt-in/opt-out mechanism. If a unit type is missing, it means the extractor found nothing to extract. Common reasons:

- The expected directory doesn't exist (e.g., no `app/decorators/` for decorators)
- The required gem isn't installed (e.g., `aasm` or `state_machines` for state machine extraction)
- The code doesn't match the extractor's expected patterns

**Fix:** Verify the code exists and matches what the extractor looks for:

```bash
# Check if the directory exists
ls app/decorators/ app/state_machines/ 2>/dev/null

# Check extraction output for that type
ls tmp/codebase_index/decorators/ tmp/codebase_index/state_machines/ 2>/dev/null
```

Note: `config.extractors` controls the **retrieval scope** (which types appear in search results), not which extractors run during extraction. See [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) for what each extractor looks for.

---

### Incremental extraction misses changes to routes, middleware, or engines

**Symptom:** After changing your routes file or adding a middleware, running `rake codebase_index:incremental` doesn't update those units.

**Cause:** Some unit types do not map to individual files and cannot be incrementally updated. The following types require a full extraction to update:

- `route` — routes are extracted from the live router, not a single file
- `middleware` — the full middleware stack is introspected at once
- `engine` — mounted engines are discovered from the app
- `scheduled_job` — job schedules are extracted from the scheduler config
- `state_machine` — multi-file extraction
- `event` — two-pass publish/subscribe collection
- `factory` — multi-file collection

**Fix:** Run a full extraction when these types change:

```bash
bundle exec rake codebase_index:extract
```

---

### Git metadata is missing or shows zeros

**Symptom:** Units have `last_modified_at: null` or `change_frequency: 0` in the JSON output.

**Cause:** The git repository is a shallow clone (common in CI with `fetch-depth: 1`). CodebaseIndex uses `git log` to compute change frequency — a shallow clone has no history to analyze.

**Fix:** Fetch at least two commits:

```yaml
# .github/workflows/index.yml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2    # minimum for incremental; use 0 for full history
```

---

## MCP Server Problems

### "No manifest.json" error when starting the Index Server

**Symptom:** `codebase-index-mcp-start` exits with an error like `No manifest.json found at /path/to/...` even though extraction completed.

**Cause:** The Index Server is using the container-internal path rather than the host-side path to the volume-mounted output. The server runs on the host and cannot access container filesystem paths.

**Fix:** Use the host path in your `.mcp.json`:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "codebase-index-mcp-start",
      "args": ["./tmp/codebase_index"]
    }
  }
}
```

Verify the output is accessible from the host:

```bash
ls ./tmp/codebase_index/manifest.json
```

If this fails, your Docker volume mount is not configured correctly. See [DOCKER_SETUP.md](DOCKER_SETUP.md).

---

### No tools appear in the MCP client

**Symptom:** The MCP client connects but shows no tools, or the server exits immediately.

**Cause:** The server failed to start, typically due to missing gem dependencies or an incorrect working directory.

**Fix:**

1. Check stderr for errors:

```bash
codebase-index-mcp-start ./tmp/codebase_index 2>&1
```

2. Ensure the gem's executables are installed:

```bash
bundle install
which codebase-index-mcp-start
```

3. For the Console Server, run the rake task directly to see error output:

```bash
bundle exec rake codebase_index:console
# Should hang waiting for MCP protocol input — if it exits, check the error
```

---

### Tier 2-4 console tools return "unsupported in embedded mode"

**Symptom:** Tools like `console_diagnose_model`, `console_eval`, or `console_sql` return an error saying they are unsupported.

**Cause:** The embedded console mode — launched via `rake codebase_index:console` or `docker compose exec ... rake codebase_index:console` — only exposes the 9 Tier 1 read-only tools. Tiers 2-4 require the bridge architecture.

**Fix:** Switch to the bridge setup. See [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) Option D for configuration. Briefly:

1. Create `~/.codebase_index/console.yml` with your connection mode
2. Update `.mcp.json` to use `codebase-console-mcp` instead of `docker exec ... rake`

---

### MCP client shows JSON parse errors

**Symptom:** The MCP client reports protocol errors, malformed JSON, or unexpected tokens.

**Cause:** Rails boot emits output to stdout (OpenTelemetry notices, gem warnings, initializer `puts` calls). The `codebase_index:console` rake task redirects stdout to stderr before Rails boots, but custom initializers that print output before this capture can break the MCP protocol.

**Fix:**

1. Check for `puts` or `print` calls in your `config/initializers/` files that run at boot.
2. Use `Rails.logger` instead of `puts` in initializers.
3. Test by running the rake task and isolating streams:

```bash
bundle exec rake codebase_index:console 2>/dev/null
# MCP protocol output (stdout) should be valid JSON-RPC
```

---

### Parallel tool calls fail together (sibling call failures)

**Symptom:** When an MCP client sends multiple tool calls in parallel and one fails, all sibling calls in the same batch also fail.

**Cause:** This is MCP client behavior, not a server bug. Some clients (including Claude Desktop and Claude Code) batch parallel tool calls into one request. If any call in the batch raises an error, the transport may reject the entire response frame.

**Fix:** There is no server-side fix. Workarounds:

1. **Send one tool call at a time.** If your client supports sequential mode, use it for unreliable calls.
2. **Validate parameters before calling.** Use `search` to confirm identifiers exist before passing them to `dependencies` or `lookup`.
3. **Avoid mixing high-risk and low-risk calls.** A `lookup` with a typo will take down a parallel `search` that would have succeeded.

---

### MCP client disconnects mid-session

**Symptom:** The MCP client reports "server disconnected" or "transport closed" during normal use.

**Cause:** Several possible causes — the server process crashed, the stdio transport pipe was broken, or the client's idle timeout expired.

**Fix:**

1. Check server stderr for crash output.
2. Use `codebase-index-mcp-start` (the self-healing wrapper) instead of `codebase-index-mcp` directly — it restarts the server on crash.
3. For Docker setups, ensure the container stays running: `docker compose exec -d app tail -f /dev/null` keeps it alive.

---

### Console queries time out on large tables

**Symptom:** `console_count` or `console_sample` times out with an error mentioning statement timeout.

**Cause:** The default statement timeout is 5000ms (5 seconds). Large tables without a scope condition can exceed this.

**Fix:** Add scope conditions to narrow the result set:

```
console_count(model: "Order", scope: { status: "pending" })
console_sample(model: "Order", scope: { created_at: { gte: "2025-01-01" } })
```

---

## Embedding Problems

### "Dimension mismatch" error when querying embeddings

**Symptom:** `codebase_retrieve` raises an error about vector dimensions not matching.

**Cause:** The embedding model was changed after embeddings were already stored. The existing vectors have a different dimensionality than the current model produces, and the vector store cannot mix them.

**Fix:** Run a full re-index to regenerate all embeddings with the new model:

```bash
bundle exec rake codebase_index:extract
bundle exec rake codebase_index:embed
```

`IndexValidator` detects the dimension mismatch and will warn you before queries fail. If you see the warning, re-index before the mismatch causes runtime errors.

---

### OpenAI API errors during embedding

**Symptom:** Embedding generation fails with `401 Unauthorized` or `429 Too Many Requests`.

**Cause:** Missing `OPENAI_API_KEY` environment variable (401), or hitting OpenAI rate limits (429).

**Fix:**

For 401 — set the API key:

```bash
export OPENAI_API_KEY=sk-...
bundle exec rake codebase_index:embed
```

Or configure it in your initializer:

```ruby
config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }
```

For 429 — embedding generation is automatically retried with backoff. If rate limits persist, consider batching with smaller codebases or switching to Ollama for local embeddings.

---

### Ollama connection refused

**Symptom:** Embedding generation fails with `Connection refused` pointing to `localhost:11434`.

**Cause:** The Ollama server is not running, or it is running on a different port.

**Fix:**

1. Start Ollama: `ollama serve`
2. Verify the model is available: `ollama list`
3. If using a non-default port, update config:

```ruby
config.embedding_options = { base_url: 'http://localhost:11434' }
```

---

## Storage Problems

### "pgvector extension not found" in PostgreSQL

**Symptom:** Running migrations or extraction fails with `PG::UndefinedObject: ERROR: type "vector" does not exist`.

**Cause:** The pgvector PostgreSQL extension is not installed in the database.

**Fix:**

```sql
CREATE EXTENSION vector;
```

Then run the CodebaseIndex pgvector generator if you haven't already:

```bash
bundle exec rails generate codebase_index:pgvector
bundle exec rails db:migrate
```

---

### Qdrant connection refused

**Symptom:** Embedding or retrieval fails with a connection error to port 6333.

**Cause:** The Qdrant server is not running.

**Fix:** Start Qdrant via Docker:

```bash
docker run -p 6333:6333 qdrant/qdrant
```

Or update your `vector_store_options` to point at the correct host/port:

```ruby
config.vector_store_options = { url: 'http://localhost:6333', collection: 'codebase_index' }
```

---

### SQLite locking errors under concurrent access

**Symptom:** Extraction or embedding fails with `SQLite3::BusyException: database is locked`.

**Cause:** SQLite does not support concurrent writers. If multiple extraction processes run simultaneously, they contend on the metadata store.

**Fix:** Use one extraction process at a time, or switch to a pgvector backend that supports concurrent access:

```ruby
CodebaseIndex.configure_with_preset(:postgresql)
```

---

## Docker Problems

### Extraction output not visible on the host

**Symptom:** `ls tmp/codebase_index/manifest.json` fails on the host after successful extraction in the container.

**Cause:** The extraction output directory (`tmp/codebase_index/`) inside the container is not volume-mounted to the host.

**Fix:** Add a volume mount to your `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - .:/app    # Full app mount — output lands at ./tmp/codebase_index/
```

Then re-run extraction. Verify on the host with `ls tmp/codebase_index/manifest.json`.

---

### Console server exits immediately with "broken pipe"

**Symptom:** The MCP client reports a broken pipe or immediate disconnection when using Docker.

**Cause:** The `-i` flag is missing from `docker exec` or `docker compose exec`. Without `-i`, stdin is not attached and the MCP protocol cannot communicate.

**Fix:** Add `-i` to your `.mcp.json`:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": ["compose", "exec", "-i", "app",
               "bundle", "exec", "rake", "codebase_index:console"]
    }
  }
}
```

---

### "No such container" error

**Symptom:** `docker exec` fails with `Error response from daemon: No such container: my_app_web_1`.

**Cause:** The container name in your `.mcp.json` or `console.yml` doesn't match the actual running container name. Docker Compose generates names following the pattern `<project>-<service>-<index>`.

**Fix:** Find the exact name:

```bash
docker ps --format '{{.Names}}'
```

Update the container name in your configuration to match exactly.

---

### Path confusion: Index Server uses container path

**Symptom:** Index Server starts but fails to load units, or `codebase-index-mcp-start` reports a missing manifest.

**Cause:** The `.mcp.json` is pointing at the container-internal path (e.g., `/app/tmp/codebase_index`) instead of the host path.

**Fix:** Use the host path in `.mcp.json`. With a standard `.:/app` volume mount, the output is at `./tmp/codebase_index` on the host:

```json
"args": ["./tmp/codebase_index"]    ✓ host path
"args": ["/app/tmp/codebase_index"]  ✗ container path — Index Server cannot read this
```

---

## Notion Integration Problems

### 401 Unauthorized from Notion API

**Symptom:** `rake codebase_index:notion_sync` fails with a 401 error.

**Cause:** The Notion API token is missing or invalid.

**Fix:** Set the token via environment variable (takes priority over config):

```bash
export NOTION_API_TOKEN=secret_...
bundle exec rake codebase_index:notion_sync
```

Or configure it in your initializer:

```ruby
config.notion_api_token = ENV['NOTION_API_TOKEN']
```

---

### 404 Not Found from Notion API

**Symptom:** Notion sync fails with a 404 error.

**Cause:** The database ID in `notion_database_ids` doesn't match any database the integration has access to.

**Fix:**

1. Verify the database ID from the Notion URL (the 32-character hex string).
2. Confirm the integration has been added to the database in Notion's share settings.

```ruby
config.notion_database_ids = {
  data_models: 'your-32-char-database-id',
  columns: 'your-other-32-char-database-id'
}
```

---

### 400 Bad Request from Notion API

**Symptom:** Notion sync fails with a 400 error mentioning property names or types.

**Cause:** The Notion database schema doesn't match the expected property structure. This happens when the database was created manually with different property names or types.

**Fix:** Use the CodebaseIndex-generated database template. Re-create the database or update its properties to match the expected schema. Check the error message for which property name caused the mismatch.

---

### Notion sync is slow but eventually succeeds

**Symptom:** Notion sync takes much longer than expected on large codebases.

**Cause:** The Notion API enforces a 3 requests/second rate limit. `RateLimiter` handles this automatically, but a codebase with hundreds of models will take proportionally longer.

**Behavior:** This is expected and handled automatically. No action needed — the sync will complete.

---

## Quick Reference

| Error message | Cause | Fix |
|---------------|-------|-----|
| `No manifest.json found` | Wrong path in `.mcp.json` | Use host path, not container path |
| `uninitialized constant Rails` | Not running inside Rails app | Run via `bundle exec rake` in Rails root |
| `type "vector" does not exist` | pgvector not installed | `CREATE EXTENSION vector` in PostgreSQL |
| `Connection refused (localhost:11434)` | Ollama not running | `ollama serve` |
| `Connection refused (localhost:6333)` | Qdrant not running | Start Qdrant container |
| `unsupported in embedded mode` | Using embedded console | Switch to bridge architecture (Option D) |
| `database is locked` | SQLite concurrent access | Run one extraction at a time |
| `Dimension mismatch` | Embedding model changed | Full re-index: extract + embed |
| `401 Unauthorized` (Notion) | Invalid API token | Check `NOTION_API_TOKEN` env var |
| `404 Not Found` (Notion) | Wrong database ID | Verify ID + integration access |
| `broken pipe` (Docker console) | Missing `-i` flag | Add `-i` to docker exec args |
| `No such container` | Wrong container name | Check with `docker ps --format '{{.Names}}'` |
| `JSON parse errors` (MCP) | Rails boot noise on stdout | Remove `puts` calls from initializers |
| Query timeout | Large table, no scope | Add scope conditions to narrow results |
| Empty extraction output | `eager_load!` failure | Check for `NameError` in boot output |
| Git metadata missing | Shallow clone in CI | Use `fetch-depth: 2` or higher |
| Parallel tool calls all fail | MCP client batches calls | Send calls sequentially, validate params first |
