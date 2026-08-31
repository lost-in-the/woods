# Troubleshooting Woods

This guide covers the most common problems encountered when installing, extracting, and using Woods. Each section follows the pattern: **symptom → cause → fix**.

---

## Extraction Problems

### Extraction produces empty or incomplete output

**Symptom:** Running `rake woods:extract` completes without errors but produces fewer units than expected, or only some model types appear.

**Cause:** `eager_load!` failed silently partway through loading your application. Zeitwerk processes directories alphabetically, if a directory early in the alphabet (e.g., `app/graphql/`) fails to load due to a missing gem, Zeitwerk aborts that pass and never reaches `app/models/`. Woods detects this and falls back to per-directory loading, but some units may still be missing.

**Fix:**

1. Check for `NameError` or `LoadError` in the extraction output:

```bash
bundle exec rake woods:extract 2>&1 | grep -i "error\|uninitialized"
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

**Cause:** Extraction requires a booted Rails environment. Woods uses runtime introspection (`ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs), these APIs do not exist outside a running Rails app.

**Fix:** Always run extraction rake tasks inside your Rails app:

```bash
# Correct: run from Rails app root
bundle exec rake woods:extract

# Docker: run inside container
docker compose exec app bundle exec rake woods:extract
```

Woods cannot extract from source files alone. It is not a static analysis tool.

---

### Extraction is very slow

**Symptom:** A full extraction is much slower than this application's established baseline.

**Cause:** Two common causes, a very large codebase (500+ models), or framework source extraction enabled on an app with many gems.

**Fix:**

Disable framework source extraction if you don't need Rails/gem internals:

```ruby
config.include_framework_sources = false
```

For subsequent runs, use incremental mode instead of full extraction:

```bash
bundle exec rake woods:incremental
```

Incremental extraction only re-extracts files that changed since the last run. It skips unchanged units and is typically 5-10× faster.

---

### Some extractor types are not appearing in output

**Symptom:** You expect state machines, events, decorators, or other unit types but they don't appear in the output directory.

**Cause:** All 34 extractors always run during extraction, there is no opt-in/opt-out mechanism. If a unit type is missing, it means the extractor found nothing to extract. Common reasons:

- The expected directory doesn't exist (e.g., no `app/decorators/` for decorators)
- The required gem isn't installed (e.g., `aasm` or `state_machines` for state machine extraction)
- The code doesn't match the extractor's expected patterns

**Fix:** Verify the code exists and matches what the extractor looks for:

```bash
# Check if the directory exists
ls app/decorators/ app/state_machines/ 2>/dev/null

# Check extraction output for that type
ls tmp/woods/decorators/ tmp/woods/state_machines/ 2>/dev/null
```

Note: `config.extractors` does not control anything today, it's accepted for forward compatibility only and is not consulted by extraction or retrieval. See [EXTRACTOR_REFERENCE.md](EXTRACTOR_REFERENCE.md) for what each extractor looks for.

---

### Incremental extraction doesn't seem to update routes, middleware, or engines

**Symptom:** After changing your routes file or adding a middleware, `rake woods:incremental` doesn't seem to update those units.

**Cause:** Nine unit types don't map to individual files, so they can't be diffed per file: `route`, `middleware`, `engine`, `scheduled_job`, `state_machine`, `factory`, `event`, `database_view`, and `rails_source`. Incremental mode still updates them, it re-runs the whole extractor when a specific trigger path changes, instead of skipping the type:

| Type | Trigger path |
|------|--------------|
| `route` | `config/routes.rb` |
| `engine` | `config/routes.rb`, `Gemfile.lock` |
| `middleware` | `config/application.rb`, `Gemfile.lock`, any file under `config/initializers`/`config/environments` |
| `scheduled_job` | `config/recurring.yml`, `config/sidekiq_cron.yml`, `config/schedule.rb` |
| `state_machine` | any `.rb` change under the scanned model directories |
| `factory` | any `.rb` change under `spec/factories`/`test/factories` |
| `event` | any `.rb` change under `app/` |
| `database_view` | any `.sql` change under `db/views` |
| `rails_source` | `Gemfile.lock` (only when `include_framework_sources` is enabled) |

If your change doesn't match one of these trigger paths, the type genuinely wasn't updated, that's the actual bug to chase, not a documented limitation.

**Fix:** Route and event changes that match the triggers above need no manual
full extraction; `woods:incremental` and `woods:watch` rerun their whole-app
extractors. If `woods:validate` still reports drift outside the trigger
contract, use a full extraction as the recovery step:

```bash
bundle exec rake woods:extract
```

---

### Git metadata is missing or shows zeros

**Symptom:** Units have `last_modified_at: null` or `change_frequency: 0` in the JSON output.

**Cause:** The git repository is a shallow clone (common in CI with `fetch-depth: 1`). Woods uses `git log` to compute change frequency, a shallow clone has no history to analyze.

**Fix:** Fetch at least two commits:

```yaml
# .github/workflows/index.yml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2    # minimum for incremental; use 0 for full history
```

---

### `manifest.json` shows the wrong branch (or `git_branch: "unknown"`) in a worktree

**Symptom:** `git_branch` / `git_sha` in `manifest.json` name a different branch than the worktree is actually on, or report `"unknown"`. The extracted units themselves are correct, only the provenance metadata is off.

**Cause:** In a linked git worktree, `.git` is a *file* containing a `gitdir:` pointer to the real git directory, often an absolute host path. When extraction runs where that path can't be resolved (e.g. inside a container where the host path isn't mounted), git can't read the ref. Woods now reports `"unknown"` in that case rather than emitting a stale, misleading value (previously it fell back to a baked `GIT_BRANCH`/`GIT_SHA` build arg).

**Fix:** Make the worktree's git directory reachable from the extraction environment, for example, mount the parent repository (the directory the `gitdir:` pointer references) into the container, or run extraction from a normal (non-worktree) checkout. With the real git directory reachable, `git_branch`/`git_sha` resolve correctly. If the checkout legitimately ships without a `.git` at all (a source tarball, or a Docker `COPY` that excludes it), set `GIT_BRANCH` / `GIT_SHA` explicitly. Woods honors these when there is no `.git` at the root (or no git binary), but suppresses them when a `.git` *is* present but unresolvable (so a stale build arg can't mask a worktree).

---

## MCP Server Problems

### "No manifest.json" error when starting the Index Server

**Symptom:** `woods-mcp-start` exits with an error like `No manifest.json found at /path/to/...` even though extraction completed.

**Cause:** The Index Server is using the container-internal path rather than the host-side path to the volume-mounted output. The server runs on the host and cannot access container filesystem paths.

**Fix:** Use the host path in your `.mcp.json`:

```json
{
  "mcpServers": {
    "codebase": {
      "command": "woods-mcp-start",
      "args": ["./tmp/woods"]
    }
  }
}
```

Verify the output is accessible from the host:

```bash
ls ./tmp/woods/manifest.json
```

**Since Woods 2.0, a healthy index may not have `manifest.json` at the output root at all.** Extraction publishes each generation into an immutable `payloads/gen-<N>/` directory and points to it from `generation.json`. If the flat path is missing, check the payload path instead before assuming extraction failed:

```bash
cat ./tmp/woods/generation.json                    # {"number": 42, "payload": "payloads/gen-42", ...}
ls ./tmp/woods/payloads/gen-42/manifest.json
```

`woods-mcp-start` and `IndexReader` already resolve this automatically, this is only for manual inspection. If neither path has a manifest, your Docker volume mount is not configured correctly. See [DOCKER_SETUP.md](DOCKER_SETUP.md).

---

### Index Server exits with `MissingArtifact`

**Symptom:** `woods-mcp` exits 2 with `MissingArtifact: No woods.json found ...`.

**Cause:** Strict mode is enabled (`WOODS_REQUIRE_INDEX=1`) but no embedding index has been written. By default the server boots without `woods.json`, it serves pattern/regex/structural tools and skips semantic search. You only see this error when you've explicitly opted into fail-closed behavior.

**Fix:** Either generate the index so semantic search is available:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed          # writes woods.json + vector dumps
```

…or unset `WOODS_REQUIRE_INDEX` to boot in pattern-only mode. (The older `WOODS_ALLOW_AUTODETECT=1` flag is no longer needed, auto-detect is the default.)

---

### `codebase_retrieve` reports degraded semantic search

**Symptom:** `codebase_retrieve` answers with a tool error carrying `error_code: degraded_index` ("Semantic search is degraded…") instead of results, and never with a silently empty context. `woods_status` shows `bootstrap.status: "degraded"`, often with a `hydration_failures` report.

**Cause:** The retriever is not healthy, and the server refuses to disguise that as "no matches". Two phases are distinguished in the error metadata:

- `phase: "boot"` — a dump failed to hydrate at startup (corrupt or unreadable `vectors.bin` / `metadata.msgpack`), so the affected in-memory store is empty. Before this guidance existed, the server reported a healthy boot and answered every query with empty results as if they were legitimate.
- `phase: "query"` — the metadata store failed while serving (storage outage, permissions). The typed `Woods::Retriever::StoreError` is mapped to the same degraded payload.

The `stores:` field names what is affected (`vector`, `metadata`, `graph`) and `reason:` carries the underlying error.

**Fix:**

1. Read `reason:` from the error payload, or call `woods_status` and read `bootstrap.reason` / `bootstrap.hydration_failures`.
2. For a `boot` failure: confirm the index directory is readable, re-run `bundle exec rake woods:embed` if the dump may be corrupt, then restart the MCP server.
3. For a `query` failure: check the backing metadata store (the SQLite database in the index directory, or your remote vector backend) for availability and permissions.

---

### No tools appear in the MCP client

**Symptom:** The MCP client connects but shows no tools, or the server exits immediately.

**Cause:** The server failed to start, typically due to missing gem dependencies or an incorrect working directory.

**Fix:**

1. Check stderr for errors:

```bash
woods-mcp-start ./tmp/woods 2>&1
```

2. Ensure the gem's executables are installed:

```bash
bundle install
which woods-mcp-start
```

3. For the Console Server, run the rake task directly to see error output:

```bash
bundle exec rake woods:console
# Should hang waiting for MCP protocol input: if it exits, check the error
```

---

### A console inventory tool is not listed

**Symptom:** A tool from the 31-schema inventory is absent from `tools/list`.

**Cause:** Supported servers advertise only executable tools: 9 Tier 1 tools by
default, plus SQL/query when explicitly enabled.

**Fix:** Enable `console_embedded_read_tools` for `console_sql` and
`console_query`. Tier 2, Tier 3, and eval remain inventory only.

---

### MCP client shows JSON parse errors

**Symptom:** The MCP client reports protocol errors, malformed JSON, or unexpected tokens.

**Cause:** Rails boot emits output to stdout (OpenTelemetry notices, gem warnings, initializer `puts` calls). The `woods:console` rake task redirects stdout to stderr before Rails boots, but custom initializers that print output before this capture can break the MCP protocol.

**Fix:**

1. Check for `puts` or `print` calls in your `config/initializers/` files that run at boot.
2. Use `Rails.logger` instead of `puts` in initializers.
3. Test by running the rake task and isolating streams:

```bash
bundle exec rake woods:console 2>/dev/null
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

**Cause:** Several possible causes, the server process crashed, the stdio transport pipe was broken, or the client's idle timeout expired.

**Fix:**

1. Check server stderr for crash output.
2. Run the configured command manually from the same `cwd` and inspect stderr. `woods-mcp-start` validates the index before launch but does not restart a crashed server.
3. For Docker setups, ensure the container stays running: `docker compose exec -d app tail -f /dev/null` keeps it alive.

---

### Console queries time out on large tables

**Symptom:** `console_count` or `console_sample` times out with an error mentioning statement timeout.

**Cause:** The default statement timeout is 5000ms (5 seconds). Large tables without a scope condition can exceed this.

**Fix:** Add scope conditions to narrow the result set:

```
console_count(model: "Order", scope: { status: "pending" })
console_sample(model: "Order", scope: { created_at_gteq: "2025-01-01" })
```

Scope keys are flat, Ransack-style predicates (`_eq`, `_gt`, `_gteq`, `_lt`, `_lteq`, `_in`, `_not_in`, `_null`, `_not_null`, `_present`, `_blank`, `_matches`) suffixed onto a column name, `scope: { created_at: { gte: "..." } }` (a nested hash) is rejected. A plain key with no suffix (`status: "pending"`) is an equality match.

---

## Embedding Problems

### Configuring vector search on MySQL

**Symptom:** You're on MySQL (or Percona / MariaDB / Aurora MySQL) and `config.vector_store = :pgvector` fails at boot, or you can't find a `:mysql` vector adapter in `lib/woods/storage/`.

**Cause:** MySQL has no native vector-search extension equivalent to `pgvector`. Woods does not emulate vector search in MySQL, every vector adapter the gem ships delegates to a real vector engine. Note that being on MySQL only constrains the *vector* choice: Woods keeps its own metadata in SQLite or memory (`metadata_store: :sqlite | :in_memory`), never in your application database, so there is no MySQL metadata adapter to configure. (Native `:mysql` / `:postgresql` metadata adapters are future work, `BACKEND_MATRIX.md` documents the shape they would take.)

**Fix:** Pair the host app with one of the supported external vector backends. Qdrant is the recommended default for self-hosted / Docker stacks:

```ruby
# config/initializers/woods.rb: MySQL host app: vectors go to Qdrant
Woods.configure do |config|
  config.metadata_store = :sqlite   # Woods-internal metadata, not your app DB
  config.vector_store = :qdrant
  config.vector_store_options = {
    url: ENV.fetch("QDRANT_URL", "http://localhost:6333"),
    collection: "woods_units",
    allow_private_hosts: true # explicit opt-in for trusted localhost/private URL
  }
  config.embedding_provider = :openai
  config.embedding_options = { api_key: ENV.fetch("OPENAI_API_KEY") }
end
```

The Postgres equivalent (in-database vectors via pgvector) is shown for contrast:

```ruby
# PostgreSQL host: vectors can live in the same database via pgvector
Woods.configure do |config|
  config.metadata_store = :sqlite
  config.vector_store = :pgvector
  config.vector_store_options = {
    connection: your_pg_connection,   # a PG::Connection to a pgvector-enabled DB
    dimensions: 1536
  }
  config.embedding_provider = :openai
  config.embedding_options = { api_key: ENV.fetch("OPENAI_API_KEY") }
end
```

For local development against a MySQL app, the `:local` preset (`Woods.configure_with_preset(:local)`, in-memory vectors, SQLite metadata, Ollama embeddings) is a reasonable stand-in. It requires the `sqlite3` gem plus a running Ollama service, but does not exercise the production vector engine. Production MySQL stacks should run Qdrant; the `:production` preset (`vector_store: :qdrant`) is the matching starting point.

See [`docs/BACKEND_MATRIX.md`](BACKEND_MATRIX.md#database-compatibility) for the full matrix and the [MySQL + Qdrant section](BACKEND_MATRIX.md#mysql--qdrant-classic-rails) for graph-traversal details (recursive CTEs on 8.0+).

---

### "Dimension mismatch" error when querying embeddings

**Symptom:** `codebase_retrieve` raises an error about vector dimensions not matching.

**Cause:** The embedding model was changed after embeddings were already stored. The existing vectors have a different dimensionality than the current model produces, and the vector store cannot mix them.

**Fix:** Run a full re-index to regenerate all embeddings with the new model:

```bash
bundle exec rake woods:extract
bundle exec rake woods:embed
```

Woods detects the dimension mismatch and raises `Woods::MCP::DimensionMismatch` rather than letting it become a runtime error: `rake woods:embed` refuses before embedding anything (comparing the provider's dimension against the width the `woods_vectors` table or Qdrant collection was created with), and the MCP server refuses at boot (comparing against the dump's WVF1 header). The message names both dimensions and the remedy, drop the vector store and re-index.

**A dimension mismatch is never silently tolerated.** If you are getting poor results without seeing this error, the cause is something else.

---

### OpenAI API errors during embedding

**Symptom:** Embedding generation fails with `401 Unauthorized` or `429 Too Many Requests`.

**Cause:** Missing `OPENAI_API_KEY` environment variable (401), or hitting OpenAI rate limits (429).

**Fix:**

For 401, set the API key:

```bash
export OPENAI_API_KEY=sk-...
bundle exec rake woods:embed
```

Or configure it in your initializer:

```ruby
config.embedding_options = { api_key: ENV['OPENAI_API_KEY'] }
```

For 429, embedding generation is automatically retried with backoff. If rate limits persist, consider batching with smaller codebases or switching to Ollama for local embeddings.

---

### Ollama connection refused

**Symptom:** Embedding generation fails with `Connection refused` pointing to `localhost:11434`.

**Cause:** The Ollama server is not running, or it is running on a different port.

**Fix:**

1. Start Ollama: `ollama serve`
2. Verify the model is available: `ollama list`
3. If using a non-default port, update config:

```ruby
config.embedding_options = { host: 'http://localhost:11434' }
```

---

### Ollama `400 "the input length exceeds the context length"`

**Symptom:** `rake woods:embed` fails with `Ollama API error: 400 {"error":"the input length exceeds the context length"}`. Individual chunks may look smaller than the configured `num_ctx`.

**Cause:** Ollama's `/api/embed` endpoint enforces the model's **native** `context_length`, not the `options.num_ctx` override (see [ollama/ollama#14186](https://github.com/ollama/ollama/issues/14186)). For `nomic-embed-text` that's 2048 tokens, regardless of what `num_ctx` is set to. Separately, without the `tokenizers` gem, Woods estimates token counts from character length, which under-counts dense Ruby source, so chunks that look safe by char count still trip the 2048-token ceiling.

**Fix:** Use Woods 2.0 and install the `tokenizers` gem:

```ruby
# Gemfile
gem 'woods', '~> 2.0'
gem 'tokenizers', '~> 0.5'   # exact BERT WordPiece token counting
```

Woods now:

1. Advertises the native context ceiling per model (2048 for `nomic-embed-text`, 8192 for `bge-m3`/`snowflake-arctic-embed2`, etc.) so the chunker sizes inputs correctly.
2. Uses the real BERT tokenizer to verify every chunk, catching the 10–20% gap between char-based estimates and Ollama's internal count.

If you want fewer chunks per unit and have the disk space, switch to a larger-context model:

```ruby
config.embedding_options = {
  model: 'bge-m3',       # 8192 native context, 1024 dims
  host: 'http://localhost:11434'
}
```

Pull the model first (`ollama pull bge-m3`) and **drop the vector index before re-embedding**: the dimension change (768 → 1024) is incompatible with existing vectors. See [EMBEDDING_MODELS.md](EMBEDDING_MODELS.md) for the full tradeoff matrix.

---

## Storage Problems

### "pgvector extension not found" in PostgreSQL

**Symptom:** Running migrations or extraction fails with `PG::UndefinedObject: ERROR: type "vector" does not exist`.

**Cause:** The pgvector PostgreSQL extension is not installed in the database.

**Fix:**

```sql
CREATE EXTENSION vector;
```

Then run the Woods pgvector generator if you haven't already:

```bash
bundle exec rails generate woods:pgvector
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
config.vector_store_options = {
  url: 'http://localhost:6333',
  collection: 'woods',
  allow_private_hosts: true
}
```

---

### SQLite locking errors under concurrent access

**Symptom:** Extraction or embedding fails with `SQLite3::BusyException: database is locked`.

**Cause:** SQLite does not support concurrent writers. If multiple extraction processes run simultaneously, they contend on the metadata store.

**Fix:** Use one embedding publisher at a time. A pgvector backend can accept
concurrent vector writes, but Woods' SQLite metadata/output artifact still
needs a coordinated publisher. Configure the hosted preset completely:

```ruby
Woods.configure_with_preset(:postgresql) do |config|
  config.embedding_options = { api_key: ENV.fetch('OPENAI_API_KEY') }
  config.vector_store_options = { connection: ActiveRecord::Base.connection }
end
```

---

## Docker Problems

### Extraction output not visible on the host

**Symptom:** `ls tmp/woods/manifest.json` fails on the host after successful extraction in the container.

**Cause:** The extraction output directory (`tmp/woods/`) inside the container is not volume-mounted to the host.

**Fix:** Add a volume mount to your `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - .:/app    # Full app mount, output lands at ./tmp/woods/
```

Then re-run extraction. Prefer `docker compose exec app bundle exec rake woods:validate` and `woods:stats`; these checks follow the active v2 generation. Host visibility is only required for an optional host-side Index Server.

---

### Console server exits immediately with "broken pipe"

**Symptom:** The MCP client reports a broken pipe or immediate disconnection when using Docker.

**Cause:** Plain `docker exec` lacks `-i`, or Docker Compose allocated its default pseudo-TTY. Either breaks stdio MCP communication.

**Fix:** Use `-T` with Compose (`stdin` remains attached), or `-i` with plain `docker exec`:

```json
{
  "mcpServers": {
    "codebase-console": {
      "command": "docker",
      "args": ["compose", "exec", "-T", "app",
               "bundle", "exec", "rake", "woods:console"],
      "cwd": "/absolute/host/path/to/app"
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

**Symptom:** Index Server starts but fails to load units, or `woods-mcp-start` reports a missing manifest.

**Cause:** The `.mcp.json` is pointing at the container-internal path (e.g., `/app/tmp/woods`) instead of the host path.

**Fix:** Use the host path in `.mcp.json`. With a standard `.:/app` volume mount, the output is at `./tmp/woods` on the host:

```text
"args": ["./tmp/woods"]     ✓ host path
"args": ["/app/tmp/woods"]  ✗ container path. Index Server cannot read this
```

---

## Notion Integration Problems

### 401 Unauthorized from Notion API

**Symptom:** `rake woods:notion_sync` fails with a 401 error.

**Cause:** The Notion API token is missing or invalid.

**Fix:** Set the token via environment variable (takes priority over config):

```bash
export NOTION_API_TOKEN=secret_...
bundle exec rake woods:notion_sync
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

**Fix:** Use the Woods-generated database template. Re-create the database or update its properties to match the expected schema. Check the error message for which property name caused the mismatch.

---

### Notion sync is slow but eventually succeeds

**Symptom:** Notion sync takes much longer than expected on large codebases.

**Cause:** The Notion API enforces a 3 requests/second rate limit. `RateLimiter` handles this automatically, but a codebase with hundreds of models will take proportionally longer.

**Behavior:** This is expected and handled automatically. No action needed, the sync will complete.

---

## Quick Reference

| Error message | Cause | Fix |
|---------------|-------|-----|
| `No manifest.json found` | Wrong index path or no published generation | Use the path visible to the server process; run `woods:validate` |
| `uninitialized constant Rails` | Not running inside Rails app | Run via `bundle exec rake` in Rails root |
| `type "vector" does not exist` | pgvector not installed | `CREATE EXTENSION vector` in PostgreSQL |
| `Connection refused (localhost:11434)` | Ollama not running | `ollama serve` |
| `Connection refused (localhost:6333)` | Qdrant not running | Start Qdrant container |
| Qdrant private/loopback URL rejected | SSRF guard is working | Add `allow_private_hosts: true` only for a deliberately trusted endpoint |
| Missing `console_sql` / `console_query` | Read tools disabled | Enable `console_embedded_read_tools` |
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
| HTTP transport refuses to start on `0.0.0.0` | Missing bearer token | Set `WOODS_MCP_HTTP_TOKEN=…` or bind loopback only |
| HTTP transport returns `403 Origin not allowed` | Origin header not in allow-list | Set `WOODS_MCP_HTTP_ALLOWED_ORIGINS="https://example.com"` (comma-separated; default is loopback-only) |
| Tool returns `error_code: :not_configured` | Feature flag or credential not set | Check `config_key` in `_meta` and the linked `doc_link` |
| Tool returns `error_code: :rate_limited` | `PipelineGuard` 5-min cooldown hit | Wait `retry_after_seconds` from `_meta`, then retry |

### First-Pass Diagnostics

For a single-call health snapshot, call the Index Server's `woods_status` tool. It reports:

- Extraction freshness (last run time, unit count, index version)
- Overall readiness plus index, watch, retriever, and bootstrap state (`ready`, `index`, `watch`, `retriever`, `bootstrap` sections)
- Which optional features are configured (embedding provider, Notion, session tracer)
- Per-feature config-key hints for anything missing
- `server.update`: the installed gem version, the newest version the process knows about (the latest published release, or the installed version itself when the install is ahead of the registry or the check could not run), and an `update_available` flag (a best-effort RubyGems check, cached 24h; disable with `WOODS_NO_UPDATE_CHECK=1`)

Agents cold-connecting to a server should call `woods_status` before any other tool, it eliminates most "why is this empty?" guesswork.

If a tool call fails with **"Tool not found: … not available in the installed Woods v…"**, the client is asking for a tool a newer gem provides. Run `bundle update woods` and reconnect the MCP server, then retry.
