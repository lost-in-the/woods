- `woods:embed` and `woods:embed_incremental` now write `woods.json` for a pgvector or Qdrant index.
  Before, they stored every vector but wrote no snapshot, so the packaged MCP server booted pattern-only.
  It now boots in semantic mode with only `WOODS_PG_URL` or `WOODS_QDRANT_URL` set.
  The vectors stay in the backend.
  The promoted dump holds `woods.json` and, when metadata is in memory, `metadata.msgpack`.
  Connection URLs, passwords and API keys are never written to it.
  An incremental run that changed nothing writes no new dump, unless no current snapshot exists yet.
