- `rails generate woods:install` prints an Index Server entry for `.mcp.json` that names no absolute path and no
  `cwd` (`bundle exec woods-mcp-start --checkout --await-index`), so one committed file works in every checkout and
  worktree on every machine. `--mcp-config` adds it to `.mcp.json` at the application root, keeping every other
  server, and never replaces an existing `woods` entry, a file that is not a JSON object, or one `woods-agent-config`
  manages: it says so and prints the entry instead. `--mcp-service <service>` gives the container form, which runs
  `docker compose exec` through `sh -c` with the session directory as `--client-root` and passes a
  developer-exported `WOODS_MCP_CLIENT_ROOT_MAP` through. An application below its checkout root gets a relative
  `WOODS_OUTPUT`.
