# Edit hooks for Claude Code and OpenCode

Edit hooks are optional. MCP reads and `woods:watch` work independently of them.
Check the installed gem exposes `woods:hook_refresh` before enabling these
unreleased adapters; updating the plugin does not update the application gem.
Start the client from the Rails application root, with an existing index.

## Supported client contracts

| Client | Verified version | Events covered |
|---|---|---|
| Claude Code | 2.1.267 | Successful `PostToolUse` for `Write` and `Edit`, using `tool_input.file_path` |
| Claude legacy compatibility | Existing single-file `MultiEdit` shape | One `tool_input.file_path`; this is not multi-file patch support |
| OpenCode | 1.18.27 | `tool.execute.after` for `apply_patch`, `write`, and `edit` |

The OpenCode patch adapter reads the successful tool's `metadata.files` array.
It includes every add, update, delete and move; a move becomes deletion of the
old path plus addition of the new path. `write` uses `metadata.filepath` and
`metadata.exists`; `edit` uses `metadata.filediff.file`. Patch text, source bytes,
diagnostics, session identifiers and arbitrary shell commands are not parsed
or placed in the queue. Actual client captures and their provenance live under
`spec/fixtures/hooks/`; the exact metadata contract is pinned to
[OpenCode v1.18.27 source](https://github.com/anomalyco/opencode/tree/v1.18.27/packages/opencode/src/tool).
See the primary [Claude hook reference](https://code.claude.com/docs/en/hooks)
and [OpenCode plugin reference](https://opencode.ai/docs/plugins/).

Other clients and arbitrary mutation tools are unsupported. Unknown shapes for
registered edit tools produce a short diagnostic instead of claiming refresh.
Use the resident watcher or an explicit extraction for unsupported operations.
OpenCode session-start/context hooks are not provided by this edit adapter.

## Claude Code registration

The Woods Claude plugin registers `woods-post-edit.sh` through its existing
`hooks/hooks.json`. The wrapper selects the explicit Claude parser, then the
shared runner handles queueing and extraction. Do not install a second copy of
the same hook. Existing single-file `MultiEdit` compatibility remains registered.

Enable the existing environment settings in the process launching the client:

```bash
export WOODS_HOOKS_ENABLED=1
# Optional; relative to the application root:
export WOODS_OUTPUT=tmp/woods
```

`WOODS_HOOKS_DISABLED=1` always wins. Enablement does not authorize Console MCP,
provider calls, user configuration writes, or daemon lifecycle changes.

## OpenCode project registration

Keep the complete Woods `plugin/` directory at a stable path visible to the
client. The Claude marketplace registration does not install a native OpenCode
plugin. Create a project-local `.opencode/plugins/woods.js` containing this one
import, replacing the path with that stable plugin location:

```javascript
export { default } from "/absolute/path/to/woods/plugin/hooks/woods-opencode.mjs";
```

OpenCode automatically loads project `.js` and `.ts` plugin files at startup.
Use the `.js` wrapper name above; copying a standalone `.mjs` file into the
autoload directory does not register it. The wrapper imports the complete
adapter and shared runner; copying only the shell entry point is insufficient.
Restart OpenCode after registration and set `WOODS_HOOKS_ENABLED=1` in its launch
environment. This setup does not require npm packages or a host Rails bundle.

The adapter uses OpenCode's `directory` as the application root and verifies
that it belongs to the supplied git `worktree`. A Rails application nested
inside a repository therefore uses its own index. Each affected path must stay
inside that application root. Linked worktrees keep separate queues and indexes.

## Queue, paths and recovery

Both adapters use the same extraction eligibility, queue, command prefix,
deadline, locks and active-daemon behavior described in
[watch hook operation](WATCH_DAEMON.md#hooks-for-agent-sessions).
`WOODS_HOOK_RAKE="docker compose exec -T app bundle exec rake"` runs extraction
inside the application container. The host needs Bash 3.2 or later, Unix tools,
and either jq or Ruby; OpenCode supplies its own JavaScript runtime.

The complete event is validated before queueing. Empty/NUL paths, traversal,
foreign-project paths and symlink path components are rejected. Deleted paths
need not exist; contained symlinks are deliberately unsupported too. Spaces,
commas, newlines and Unicode paths remain intact. Adapter input is limited to
1 MiB and 1,000 affected paths; the OpenCode handoff is additionally limited to
48 KiB. An unsupported oversized event requires explicit extraction or watch.

One immutable queue file holds a multi-file event. The owner batches up to
16 files, 1,000 paths and 48 KiB without splitting an event. Existing single-path
queue records remain readable. A successful task, including a confirmed no-op,
acknowledges the batch; failure, timeout or daemon exit 75 retains every path.
At-least-once delivery can repeat work after a crash or event replay.

The OpenCode callback hands the event to a detached runner, which owns its
existing deadline. Callback completion means handoff, not index publication.
Inspect `<output>/hook.log`, the pending queue and the published generation to
confirm refresh. Malformed input diagnostics omit the original tool payload.
For rollback, disable hooks before removing registration; preserve pending
multi-file records until a compatible runner has consumed them.
