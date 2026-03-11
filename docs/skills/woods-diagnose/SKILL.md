---
name: codebase-index-diagnose
description: Systematic troubleshooting for CodebaseIndex — diagnose extraction, MCP, embedding, and storage issues
---

# CodebaseIndex Diagnosis Workflow

Work through these steps in order. Most problems are caught by Step 1 or Step 2.

---

## Step 1: Verify Rails Boots

CodebaseIndex requires a booted Rails environment. If Rails can't boot, extraction produces no output.

```bash
bundle exec rails runner 'puts Rails.version'
```

**Docker variant:**

```bash
docker compose exec app bundle exec rails runner 'puts Rails.version'
```

**If this fails:** Fix the Rails boot error before continuing. Common causes: missing environment variables, database not running, syntax error in an initializer.

Check for `NameError` during eager loading — this is a frequent cause of partial extractions:

```bash
bundle exec rails runner 'Rails.application.eager_load!; puts "OK"' 2>&1 | head -40
```

If you see `NameError` mentioning a graphql or other gem, that directory is failing to load. Add it to `config.eager_load_paths` exclusions or install the missing gem.

---

## Step 2: Check Extraction Output

```bash
ls -la tmp/codebase_index/
cat tmp/codebase_index/manifest.json
```

**If `manifest.json` is missing:** Extraction never completed. Run it and watch for errors:

```bash
bundle exec rake codebase_index:extract 2>&1 | tee /tmp/extraction.log
```

Look for `ExtractionError` or `NameError` lines in the output.

**If `total_units` is 0 or very low:** Rails booted but eager loading failed to load your models. See [Models missing from extraction](#models-missing-from-extraction) below.

**If counts look right:** Continue to Step 3.

Validate index integrity:

```bash
bundle exec rake codebase_index:validate
```

---

## Step 3: Test MCP Server

Test the Index Server directly:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | codebase-index-mcp-start ./tmp/codebase_index
```

**Expected:** A JSON response with a `tools` array containing 27+ entries.

**If you get "manifest.json not found":** The path is wrong. Check that `./tmp/codebase_index/manifest.json` exists and that you're running from the Rails app root.

**If you get no response at all:** The binary may not be in your PATH. Try:

```bash
which codebase-index-mcp-start
# If missing:
gem install codebase_index
# or if using Bundler:
bundle exec codebase-index-mcp-start ./tmp/codebase_index
```

Test the Console Server:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bundle exec rake codebase_index:console
```

**Expected:** JSON tool list, then the process hangs (waiting for more input). Press Ctrl+C.

**If it exits immediately:** Run without piped input to see the error:

```bash
bundle exec rake codebase_index:console
```

---

## Step 4: Check Embeddings (if configured)

If `codebase_retrieve` returns "Embedding provider is not available":

```bash
bundle exec rails runner '
  config = CodebaseIndex.configuration
  puts "Provider: #{config.embedding_provider.inspect}"
  puts "Model: #{config.embedding_model.inspect}"
  puts "Vector store: #{config.vector_store.inspect}"
'
```

**OpenAI:** Verify `OPENAI_API_KEY` is set and the model name is valid (`text-embedding-3-small` is the default).

**Ollama:** Verify Ollama is running: `curl http://localhost:11434/api/tags`

**Dimension mismatch:** If you switched embedding models after initial indexing, you need a full re-index:

```bash
bundle exec rake codebase_index:extract   # re-extract to reset unit files
bundle exec rake codebase_index:embed     # re-embed all units
```

`IndexValidator` will detect dimension mismatches and log an error on startup.

---

## Decision Tree

### Extraction empty → check eager_load

```
total_units == 0?
  ├─ rails runner 'puts Rails.version' fails?
  │   └─ Fix Rails boot error first
  └─ boots OK?
      ├─ rails runner 'Rails.application.eager_load!; puts "OK"' raises NameError?
      │   └─ A directory is failing to load — check app/graphql/, app/admin/, etc.
      └─ eager_load OK but models still missing?
          └─ Check that models inherit ActiveRecord::Base and table exists
```

### MCP server: no tools visible

```
tools/list returns empty or error?
  ├─ Index Server path wrong?
  │   └─ Verify manifest.json exists at the path provided
  ├─ Binary not found?
  │   └─ gem install codebase_index or use bundle exec
  └─ Console Server exits immediately?
      └─ Run without pipe to see error; check Rails boot + cwd setting
```

### Console shows only 9 tools (Tier 1 only)

This is expected behavior for embedded mode (rake task / Docker). Tier 2–4 tools (`console_diagnose_model`, `console_eval`, `console_sql`, etc.) require bridge mode.

To get all 31 tools, switch to Option D (SSH/bridge) from [CONSOLE_MCP_SETUP.md](../../CONSOLE_MCP_SETUP.md).

### MCP client shows "connection refused" on HTTP transport

```
console_mcp_enabled set to true?
  ├─ No → Add to initializer and restart Rails
  └─ Yes → Is Rails running?
      ├─ No → Start the server
      └─ Yes → curl http://localhost:3000/mcp/console
               200 or 405 = middleware mounted ✓
               404 = path mismatch — check console_mcp_path config
```

### Slow response times / timeouts

Default statement timeout is 5000ms. For large tables, narrow the query with `scope`:

```json
{ "model": "Order", "scope": { "status": "pending" } }
```

If `pipeline_extract` or `pipeline_embed` are rate-limited, wait 5 minutes (the cooldown period) or use `pipeline_repair` with `action: "reset_cooldowns"`.
