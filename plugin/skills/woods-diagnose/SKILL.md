---
name: woods-diagnose
description: Use when Woods extraction, index validation, MCP connection, semantic retrieval, storage, or Console access is failing or stale.
---

# Woods diagnosis

Change nothing until the failing layer is identified. Diagnose the installed version:

```bash
bundle info woods
git status --short --branch
```

This skill targets Woods 2.0.0 or later.

## 1. Check Rails

```bash
bundle exec rails runner 'puts Rails.application.class.name'
bundle exec rails runner 'Rails.application.eager_load!; puts "eager load ok"'
```

Use the application's normal Docker command and environment variables when applicable. Fix boot/eager-load failures before Woods.

## 2. Check the published index

```bash
bin/rails woods:validate
bin/rails woods:stats
```

If missing or stale, run the narrow maintenance path justified by the evidence: `woods:incremental` for known file changes or `woods:extract` for first run, broad change, upgrade, or drift. Woods tasks understand `generation.json`; do not assume `manifest.json` is at the root.

If a one-shot extraction raises `Could not publish generation`, the candidate
payload was written but never made visible; readers still serve the previous
complete generation. Fix the named filesystem, permission, space, or mount
failure and rerun the same task. Never edit `generation.json` or point a reader
at the unreachable payload by hand.

## 3. Check the MCP process and path

Compare the client config with the exact command, absolute `cwd`, bundle, and index path visible to that process. Run the configured executable manually to read stderr. For a host bundle:

```bash
bundle exec woods-mcp-start ./tmp/woods
```

Then reconnect through the MCP client and call `woods_status`. Use client-native tool inspection after initialization. Expect 14 packaged Index tools, not all conditional schemas.

For Docker-only bundles, test the configured container command instead, for example `docker compose exec -T app bundle exec woods-mcp /app/tmp/woods`. Use the container path for a container process and a host path only for a host process.

## 4. Check semantic retrieval

Only diagnose this layer when structural tools work and `codebase_retrieve` fails. Check `woods_status`, configured provider/model/vector store, provider reachability, and whether `woods:embed` completed.

- OpenAI: verify the key exists without printing it.
- Ollama: verify the service and configured model locally.
- Stale vectors: run the documented embed refresh.
- Dimension mismatch: rebuild into a store matching the configured model; do not suppress the preflight.
- Purge guard: back up and inspect the proposed deletion; never set `WOODS_ALLOW_PURGE` without explicit approval.

## 5. Check Console separately

Console failures are live Rails/config/security failures, not Index failures. Verify authorized environment, Rails boot, `WOODS_CONSOLE_CONFIG` or direct `cwd`, blocked-table policy, credentials, and stderr.

Nine tools are normal. Eleven appear only with `console_embedded_read_tools`. Do not chase Tier 2/3 or `console_eval`; they do not register in supported packaged modes. Never work around redaction, credential scanning, SQL validation, or a block.

## Report

Return the first failing layer, commands/evidence, root-cause hypothesis, whether any file changed, and the smallest next action. If a fix is requested, change one thing and rerun the failing check before proceeding.

Canonical guide: [TROUBLESHOOTING.md](https://github.com/lost-in-the/woods/blob/main/docs/TROUBLESHOOTING.md).
