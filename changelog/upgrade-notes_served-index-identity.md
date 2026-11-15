- `woods-mcp-start` now refuses an index another checkout of the repository recorded.
  When the checkout containing the index's recorded root (or, without one, the index directory) differs from the
  checkout containing the launcher's working directory, it exits 1 naming both and the remedy.
  Pass `--allow-mismatch` or set `WOODS_MCP_ALLOW_MISMATCH=1` to serve it anyway; either prints a warning.
  An index copied by hand into another worktree is refused there; `woods:seed` rewrites the recorded root instead.
  Two cases still start without a refusal, by design: a launch from outside any checkout, and an index whose
  recorded root cannot be found on this machine and whose own directory is outside any checkout
  (for example a downloaded index in a plain directory).
  Branch differences only warn, and `woods-mcp` itself never refuses.
- The `woods_status` report gains a leading `identity` key, and `instructions` no longer start with
  "Start with woods_status": they lead with the identity line.
