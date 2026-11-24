- The Console MCP server is removed.
  It let an agent query a live application through Active Record and filtered secrets out of the output.
  That filtering cannot be made complete, and keeping it safe is not viable, so Woods no longer ships it.
  Gone: the server and its tools, the server behind `rake woods:console`, `exe/woods-console` and `woods-console-mcp`,
  the automatic `/mcp/console` mount, the Console section of the install template, and the Console guide.
  Those entry points remain only to stop with the removal message (see the upgrade notes).
  The credential scanner that extraction and the exports use stays, as `Woods::CredentialScanner`.
  `docs/CONSOLE_REMOVED.md` lists the cleanup steps.
