# Woods Testbed

A persistent, reusable Rails 8 environment for exercising the Woods gem against
a real host application — without touching the admin app or production code.

## What it is

The testbed is a minimal Rails 8.0 app (the Rails Tutorial sample app — User,
Micropost, Relationship, Credential models) running in Docker with the Woods gem
mounted as a live path dependency. You can run full extraction, hit the ERD
endpoint, use the Console MCP server, and verify gem behaviour without spinning
up compose-dev.

It is the right place to test:
- ERD schema generation and the `/woods/erd/schema.json` endpoint
- Extraction output shape (new extractors, metadata fields, dependency edges)
- Console MCP integration
- Rake task behaviour (`woods:extract`, `woods:incremental`, `woods:stats`)
- Any new feature that needs a booted Rails environment before the admin app

## Locations

| Thing | Path |
|---|---|
| Compose file + Dockerfile | `/Users/leah/lost-in-the/woods-erd/docs/testbed/` |
| Host Rails app | `~/work/woods-testbed/rails-app/` |
| Bundle volume | Docker volume `woods-testbed-bundle` |
| Port (default) | `3010` (host) → `3000` (container) |

The compose file and Dockerfile live inside the gem repo so every worktree has
them. The host app lives outside the repo so it is not version-controlled as part
of the gem.

## Starting the testbed

```bash
cd /Users/leah/lost-in-the/woods-erd/docs/testbed
docker compose up -d
```

Default: mounts the `woods-erd` worktree (`/Users/leah/lost-in-the/woods-erd`)
as the gem and binds port 3010 on the host.

First-time only — create and migrate the database:

```bash
docker compose exec app bin/rails db:create db:migrate
```

## Pointing at a different Woods worktree

Override `WOODS_GEM_PATH` at startup. The bundle volume is reused so only gems
that changed between worktrees need reinstalling (usually just `woods` itself,
which is a path dep and requires no download).

```bash
WOODS_GEM_PATH=/Users/leah/lost-in-the/woods-flow docker compose up -d
```

Or for an ad-hoc command without restarting:

```bash
WOODS_GEM_PATH=/Users/leah/lost-in-the/woods-hardening docker compose run --rm app bundle exec rake woods:stats
```

After switching worktrees, restart the server so Rails picks up the new gem code:

```bash
docker compose restart app
```

## Changing the port

Override `TESTBED_PORT`:

```bash
TESTBED_PORT=4000 docker compose up -d
```

## Re-extracting after gem changes

Extraction runs inside the container against the mounted host app:

```bash
docker compose exec app bundle exec rake woods:extract
```

The output lands in `/app/tmp/woods` inside the container, which is
`~/work/woods-testbed/rails-app/tmp/woods` on the host (volume-mounted bind).

Stats:

```bash
docker compose exec app bundle exec rake woods:stats
```

Incremental (changed files only):

```bash
docker compose exec app bundle exec rake woods:incremental
```

After re-extraction, the ERD endpoint reflects the new data immediately — no
restart required (it reads from `tmp/woods` on each request).

## Verifying the ERD endpoint

After extraction, hit:

```bash
curl -s http://localhost:3010/woods/erd/schema.json | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print('entryPoints:', len(d.get('entryPoints', []))); print('tables:', list(d.get('tables', {}).keys()))"
```

Expected output for the default host app (Rails Tutorial sample):

```
entryPoints: 16
tables: ['users', 'microposts', 'relationships']
```

The frontend ERD viewer (Liam) can be pointed at `http://localhost:3010/woods/erd`
to browse the interactive diagram.

## What's in the host app

The host app is the [Rails Tutorial](https://railstutorial.org/) sample app
(chapter 14 state) — a realistic social-micro-blogging app with:

- **Models:** User (has_many microposts, followers/following through Relationship),
  Micropost (belongs_to user, image attachment), Relationship, Credential
- **Controllers:** Users, Sessions, Microposts, Relationships,
  AccountActivations, PasswordResets, StaticPages
- **Jobs:** AccountActivationJob (implicit via mailer)
- **Mailers:** UserMailer (account activation + password reset)
- **Tests:** Minitest suite under `test/`
- **DB:** SQLite (development + test), PostgreSQL config for production (unused)

### Adding fixtures

To add a new model, controller, or service for testing a specific extractor:

1. Create the file under `~/work/woods-testbed/rails-app/app/`
2. Add the migration if needed and run `docker compose exec app bin/rails db:migrate`
3. Re-run extraction: `docker compose exec app bundle exec rake woods:extract`

Files under `tmp/`, `log/`, and `storage/` are gitignored in the host app and
should not be committed.

## Stopping and cleanup

Stop (keeps bundle volume and extraction output):

```bash
docker compose down
```

Full reset (removes container but keeps bundle volume — bundle install is slow):

```bash
docker compose down
docker compose up -d
```

Nuke the bundle volume too (forces full reinstall, takes ~2 min):

```bash
docker compose down -v
docker compose up -d
```

## Known gotchas

- **Git warnings during extraction** — `fatal: not a git repository` appears
  because the host app isn't a git repo. The git metadata extractor gracefully
  skips; extraction still completes.

- **Worktree switch requires restart** — After changing `WOODS_GEM_PATH`, Rails
  has already loaded the old gem code. `docker compose restart app` forces a
  clean boot against the new mount.

- **Bundle volume drift** — The bundle volume persists across worktree switches.
  If a worktree adds or removes a gem dependency, the container's `bundle install`
  step (which runs on startup) handles it automatically. If you see gem resolution
  errors, clear the volume with `docker compose down -v`.

- **Initializer must match the gem's Configuration API** — The initializer at
  `~/work/woods-testbed/rails-app/config/initializers/woods_console.rb` uses
  `config.console_redacted_columns`, which is the attribute name in the `erd`
  worktree. If you switch to a worktree that uses a different attribute name
  (e.g. `console_blocked_tables` from an older branch), Rails will fail to boot
  with a `NoMethodError`. Check `Woods::Configuration` attrs in the target
  worktree's `lib/woods.rb` before switching.

- **Port conflicts** — Default port is 3010. If something else is bound to 3010,
  set `TESTBED_PORT` to a free port.

- **SQLite DB lives in the bind-mounted host app** — The DB file is at
  `~/work/woods-testbed/rails-app/db/development.sqlite3`. It survives container
  restarts (it's not in the container layer). Run `db:migrate` after the first
  `docker compose up` and after adding migrations.
