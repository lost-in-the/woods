---
name: woods-diagnose
description: Systematic troubleshooting for Woods: diagnose extraction, MCP, embedding, and storage issues
---

# Woods Diagnosis Workflow

Work through these steps in order. Most problems are caught by Step 1 or Step 2.

---

## Version Preflight

Confirm which Woods version is installed and diagnose only against it:

```bash
bundle info woods        # installed version + path
```

This guide targets **Woods 2.0.0 or later**.

- Older gem: some commands, tools, or config keys below will not exist. Tell the user to run `bundle update woods` first.
- Newer release on RubyGems: mention it so the user can pick it up.

---

## Step 1: Verify Rails Boots

Woods requires a booted Rails environment. If Rails can't boot, extraction produces no output.

```bash
bundle exec rails runner 'puts Rails.version'
```

**Docker variant:**

```bash
docker compose exec app bundle exec rails runner 'puts Rails.version'
```

**If this fails:** Fix the Rails boot error before continuing. Common causes: missing environment variables, database not running, syntax error in an initializer.

Check for `NameError` during eager loading. This is a frequent cause of partial extractions:

```bash
bundle exec rails runner 'Rails.application.eager_load!; puts "OK"' 2>&1 | head -40
```

If you see `NameError` mentioning a graphql or other gem, that directory is failing to load. Add it to `config.eager_load_paths` exclusions or install the missing gem.

---

## Step 2: Check Extraction Output

```bash
ls -la tmp/woods/
gen=$(jq -r '.payload // empty' tmp/woods/generation.json 2>/dev/null)
cat "tmp/woods/${gen:-.}/manifest.json"
```

(Extraction publishes into `tmp/woods/payloads/gen-<N>/` and `generation.json`
points at the current one. A bare `cat tmp/woods/manifest.json` will miss it
except on an index written before payloads existed, where `${gen:-.}` falls
back to the flat root.)

**If `manifest.json` is missing:** Extraction never completed. Run it and watch for errors:

```bash
bundle exec rake woods:extract 2>&1 | tee /tmp/extraction.log
```

Look for `ExtractionError` or `NameError` lines in the output.

**If `total_units` is 0 or very low:** Rails booted but eager loading failed to load your models. See [Extraction empty → check eager_load](#extraction-empty--check-eager_load) in the Decision Tree below.

**If counts look right:** Continue to Step 3.

Validate index integrity:

```bash
bundle exec rake woods:validate
```

---

## Step 3: Test MCP Server

Test the Index Server directly:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | woods-mcp-start ./tmp/woods
```

**Expected:** A JSON response with a `tools` array holding at least the 14 always-on tools:

- Query: `lookup`, `search`, `dependencies`, `dependents`, `structure`, `framework`, `recent_changes`
- Graph: `graph_analysis`, `domain_clusters`, `pagerank`, `trace_flow`
- Retrieval and ops: `codebase_retrieve`, `reload`, `woods_status`

Never expect all 29 by default. The other 15 register only when their collaborator (operator, feedback store, snapshots, Notion) is configured.

**If you get "manifest.json not found":** The path is wrong, or the index is payload-born and nothing is reading `generation.json`'s pointer. Check that `./tmp/woods/generation.json` (or the older flat `./tmp/woods/manifest.json`) exists and that you're running from the Rails app root.

**If you get no response at all:** The binary may not be in your PATH. Try:

```bash
which woods-mcp-start
# If missing:
gem install woods
# or if using Bundler:
bundle exec woods-mcp-start ./tmp/woods
```

Test the Console Server:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bundle exec rake woods:console
```

**Expected:** JSON tool list, then the process hangs (waiting for more input). Press Ctrl+C.

**If it exits immediately:** Run without piped input to see the error:

```bash
bundle exec rake woods:console
```

---

## Step 4: Check Embeddings (if configured)

If `codebase_retrieve` returns "Embedding provider is not available":

```bash
bundle exec rails runner '
  config = Woods.configuration
  puts "Provider: #{config.embedding_provider.inspect}"
  puts "Model: #{config.embedding_model.inspect}"
  puts "Vector store: #{config.vector_store.inspect}"
'
```

**OpenAI:** Verify `OPENAI_API_KEY` is set and the model name is valid (`text-embedding-3-small` is the default).

**Ollama:** Verify Ollama is running: `curl http://localhost:11434/api/tags`

**Dimension mismatch:** If you switched embedding models after initial indexing, you need a full re-index:

```bash
bundle exec rake woods:extract   # re-extract to reset unit files
bundle exec rake woods:embed     # re-embed all units
```

Woods raises `Woods::MCP::DimensionMismatch` on a dimension mismatch. `rake
woods:embed` refuses before embedding anything, and the MCP server refuses at
boot. The message names the stored dimension, the provider dimension, and the
remedy.

---

## Decision Tree

### Extraction empty → check eager_load

```
total_units == 0?
  ├─ rails runner 'puts Rails.version' fails?
  │   └─ Fix Rails boot error first
  └─ boots OK?
      ├─ rails runner 'Rails.application.eager_load!; puts "OK"' raises NameError?
      │   └─ A directory is failing to load. Check app/graphql/, app/admin/, etc.
      └─ eager_load OK but models still missing?
          └─ Check that models inherit ActiveRecord::Base and table exists
```

### MCP server: no tools visible

```
tools/list returns empty or error?
  ├─ Index Server path wrong?
  │   └─ Verify manifest.json exists at the path provided
  ├─ Binary not found?
  │   └─ gem install woods or use bundle exec
  └─ Console Server exits immediately?
      └─ Run without pipe to see error; check Rails boot + cwd setting
```

### Console shows only 9 tools (Tier 1 only)

This is expected in every mode. The rake task, Docker exec, and the launcher wrapper all start the same embedded server.

| Tier | Registers? | Example |
|---|---|---|
| Tier 1 (9 tools) | Always | `console_count`, `console_schema` |
| `console_sql`, `console_query` | With `config.console_embedded_read_tools = true` (11 total) | `console_sql` |
| Tier 2 | Never (schema only) | `console_diagnose_model` |
| Tier 3 | Never (schema only) | `console_slow_endpoints` |
| `console_eval` | Never | |

Don't chase a "bridge" or a higher tier; none ships. See [CONSOLE_MCP_SETUP.md](https://github.com/lost-in-the/woods/blob/main/docs/CONSOLE_MCP_SETUP.md#tool-support-by-mode).

### MCP client shows "connection refused" on HTTP transport

```
console_mcp_enabled set to true?
  ├─ No → Add to initializer and restart Rails
  └─ Yes → Is Rails running?
      ├─ No → Start the server
      └─ Yes → curl http://localhost:3000/mcp/console
               200 or 405 = middleware mounted ✓
               404 = path mismatch. Check console_mcp_path config
```

### Slow response times / timeouts

Default statement timeout is 5000ms. For large tables, narrow the query with `scope`:

```json
{ "model": "Order", "scope": { "status": "pending" } }
```

If `pipeline_extract` or `pipeline_embed` are rate-limited, wait 5 minutes (the cooldown period) or use `pipeline_repair` with `action: "reset_cooldowns"`.
