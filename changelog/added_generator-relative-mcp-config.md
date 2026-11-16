- `rails generate woods:install` prints an Index Server entry for `.mcp.json` that names no absolute path and no
  `cwd`, so one committed file works in every checkout and worktree on every machine. It runs
  `bundle exec woods-mcp-start --checkout --await-index` through `sh`, after changing into `CLAUDE_PROJECT_DIR` when
  the client sets it, and into the application directory for an application below its checkout root (Bundler looks
  for the Gemfile up from the working directory, never down). It writes every variable as `$NAME`, never `${NAME}`,
  which Claude Code rewrites from its own environment. A configured `output_dir` inside the checkout becomes the
  entry's `WOODS_OUTPUT`; one outside it cannot be served by `--checkout`, and the generator says so.
  `--mcp-config` adds it to `.mcp.json` at the application root, keeping every other server, and never
  replaces an existing `woods` entry, a file that is not a JSON object, or one `woods-agent-config` manages: it says
  so and prints the entry instead. `--mcp-service <service>` gives the container form, which runs
  `docker compose exec` with the session directory as `--client-root` and passes a developer-exported
  `WOODS_MCP_CLIENT_ROOT_MAP` through. An application below its checkout root gets a relative `WOODS_OUTPUT`.
  The container entry passes no `-w`: the service's `working_dir` must be the application root, in a mount of the
  whole checkout. A `.mcp.json` that cannot be read is skipped with the reason, and an `output_dir` inside the
  checkout is followed when the application is reached through a symlink.
