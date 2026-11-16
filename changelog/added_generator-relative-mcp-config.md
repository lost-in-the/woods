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
- `woods-agent-config setup --scope project` writes the same checkout-aware entry, from one shared builder, for a
  new installation inside a git checkout: no absolute path, no `cwd` and no `BUNDLE_GEMFILE` (Bundler finds the
  Gemfile from the project directory). `--entry-form relative|absolute` chooses explicitly; the plan summary names
  `entry_form` and the receipt records it. An existing installation keeps its form (a receipt without one counts
  as absolute): `setup --entry-form relative` over it refuses, and `update --entry-form relative` migrates it. User
  scope, and a root outside any git checkout, stay absolute. Preflight checks that the installed Woods accepts
  `--checkout --await-index` and that a git checkout contains the root where the server runs.
  Setup in another checkout of a committed relative entry adopts it, byte-identical to what it would write, and
  writes only that checkout's own receipt (`"adopted": true`); a different or absolute unowned entry is still
  refused. The plan's `notes` say what the tool does not do itself: keep the receipt out of version control, and for
  Compose, run the service with the application root as its `working_dir` and pin the project name for worktrees.
