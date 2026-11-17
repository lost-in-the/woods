- When the index directory does not exist, `woods-mcp` and `woods-mcp-start` now say that the process sees
  nothing at that path, and that a server run inside a container needs the container path (for example
  `/app/tmp/woods`) while a server on the host needs the host path, before the extract advice.
