- `woods-mcp-start --checkout` (`WOODS_MCP_CHECKOUT=1`) takes no index path: it serves `tmp/woods`, or
  `WOODS_OUTPUT`, in the checkout it is started in, so a linked worktree serves its own index and a project
  configuration needs no absolute path.
  `--await-index` (`WOODS_MCP_AWAIT_INDEX=1`, also on `woods-mcp`) starts the server before an index exists:
  it completes the handshake with the usual tools, `woods_status` reports `index.state: "awaiting_index"` (and the
  `started_at`, `command` and `state` of a `.bootstrap.json` a launcher wrote), every other tool answers a
  retryable `building` result, and the first published generation is served on the next call, with no restart.
  `--client-root` (`WOODS_MCP_CLIENT_ROOT`), with an optional `--client-root-as` (`WOODS_MCP_CLIENT_ROOT_AS`),
  compares the index with the client session's checkout instead of the launcher's directory, so a launcher inside a
  shared container refuses, or warns about, a session in another worktree.
  When either checkout cannot be determined, the instructions and the new `woods_status.identity.warnings` now
  carry one `WARNING:` line; these launches used to start silently.
  Without the new flags, every launch starts or is refused exactly as before.
