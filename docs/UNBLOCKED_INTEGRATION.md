# Unblocked Integration

Woods can sync extraction data to [Unblocked](https://getunblocked.com) via its
Documents API. This gives Unblocked's automated code review and Q&A tools
structural codebase context, associations, blast radius, entry points, side
effects, alongside the institutional context (PRs, Slack, tickets) it already
provides.

## How It Works

1. **Extract** codebase data with `woods:extract` (the usual pipeline)
2. **Sync** to Unblocked with `woods:unblocked_sync` (or the alias `woods:relay`)
3. Documents appear in your Unblocked collection within ~1 minute
4. Unblocked's code review agent and Q&A tools reference the structural context

Documents are **upserted by URI**: running sync again updates existing documents
without creating duplicates. URIs point to your GitHub repository for working
citation links in Unblocked answers.

## Setup

### 1. Create an Unblocked Collection

Collections for custom sources are created **via the API** (the web app does
not currently offer a creation path for them):

```bash
curl -X POST https://getunblocked.com/api/v1/collections \
  -H "Authorization: Bearer $UNBLOCKED_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Codebase Architecture", "description": "Structural metadata from Woods extraction, models, controllers, services, dependencies, and blast radius analysis.", "iconUrl": "https://raw.githubusercontent.com/lost-in-the/woods/main/assets/woods-mark-black.svg"}'
```

> **Known API quirk:** the live API rejects collection creation with a bare
> `400 Bad Request` unless `iconUrl` is included, even though the API docs mark
> it optional. Always pass an `iconUrl`, the Woods mark above is a stable,
> repo-hosted square SVG you can use directly.

Creating the collection from Ruby is simpler, `Client#create_collection`
defaults `iconUrl` to the Woods mark (`Client::DEFAULT_ICON_URL`), so the quirk
can't bite:

```ruby
require 'woods/unblocked/client'

client = Woods::Unblocked::Client.new(api_token: ENV['UNBLOCKED_API_TOKEN'])
collection = client.create_collection(
  name: 'Codebase Architecture',
  description: 'Structural metadata from Woods extraction, models, ' \
               'controllers, services, dependencies, and blast radius analysis.'
)
collection['id'] # => use as UNBLOCKED_COLLECTION_ID
```

Pass `icon_url:` to use your own icon instead of the default.

### 2. Create an API Token

In the Unblocked web app: **Settings** → **API Tokens** → **Create Token**.

- **Personal Access Token**: 1,000 API calls/day, scoped to your account
- **Team Access Token**: access to all team documents (recommended for CI)

### 3. Configure Woods

Via environment variables (recommended for CI):

```bash
export UNBLOCKED_API_TOKEN="ubk_..."
export UNBLOCKED_COLLECTION_ID="12345678-abcd-..."
export UNBLOCKED_REPO_URL="https://github.com/your-org/your-repo"
```

Or in your initializer:

```ruby
Woods.configure do |config|
  config.unblocked_api_token = ENV["UNBLOCKED_API_TOKEN"]
  config.unblocked_collection_id = ENV["UNBLOCKED_COLLECTION_ID"]
  config.unblocked_repo_url = "https://github.com/your-org/your-repo"
end
```

### 4. Run the Sync

```bash
bundle exec rake woods:extract        # Extract codebase data
bundle exec rake woods:unblocked_sync # Sync to Unblocked
```

Or in Docker:

```bash
docker compose exec app bin/rails woods:extract
docker compose exec app bin/rails woods:unblocked_sync
```

## What Gets Synced

| Unit Type | Strategy | Typical Count |
|-----------|----------|---------------|
| Models | All | 100-300 |
| Controllers | All | 100-400 |
| Services | All | 20-50 |
| Jobs | All | 50-150 |
| GraphQL types/resolvers | All | 100-400 |
| Concerns | All | 20-50 |
| Mailers | All | 3-10 |
| Managers | All | 10-30 |
| Decorators | All | 10-30 |
| POROs | Top 100 by dependents | 100 max |
| Libs | Top 50 by dependents | 50 max |

Total: ~800-1200 documents depending on app size.

## Document Format

Each document is a condensed Markdown profile optimized for code review context.

**Models** (highest value) include:
- Association summary grouped by type (belongs_to/has_many/has_one)
- Dependent count by type with blast radius assessment
- Entry points (controllers, GraphQL resolvers, jobs)
- Schema highlights (enums, scopes, concerns, callbacks)
- Side effects (workers, mailers triggered)

**Controllers** include routes, inheritance chain, model dependencies, view templates.

**Services/Jobs/Other types** include dependencies, dependents summary, key
structural data.

## URI Scheme

Document URIs point to the source file on GitHub:

```
https://github.com/your-org/your-repo/blob/main/app/models/order.rb
```

This means Unblocked citations link directly to the relevant source code.

Different identifiers defined in one synced file retain the existing URI
rule: the lexically first identifier keeps the bare URI; siblings use
`?unit=<encoded identifier>`. Original identifiers and unambiguous URIs do
not change when two extracted types share a name but have different files.

Two **different types with the same identifier and source file** cannot be
represented by this URI rule. Woods reports `ambiguous export URI` and skips
all documents sharing that base URI. It also disables stale-document deletion
for that run, including with `UNBLOCKED_FORCE_PURGE=1`. Existing remote
documents remain untouched. This is a deliberate refusal pending an explicit
remote URI migration; renaming public extraction identifiers is not required.
Collision detection includes all published types, including excluded types
and units outside a partial sync's top-N selection.

## Rate Limits

The Unblocked API allows 1,000 calls per day (resets at midnight PST). A typical
sync uses ~800-1200 calls for the initial build. If your app exceeds 1,000 units:

- The sync stops gracefully when the budget is exhausted
- Re-run the next day to continue where it left off (upsert is idempotent)
- Set `UNBLOCKED_DAILY_BUDGET` to adjust the limiter if your plan allows more

## CI Integration

Add a post-merge step. The sync is incremental (see below), so the one thing CI
must do beyond running the task is **persist the sync manifest between runs**, otherwise every deploy starts from scratch and re-pushes everything.

### GitHub Actions

`actions/cache` entries are **immutable**: an exact-key hit skips the post-job
save, which would freeze the manifest at its first-run state forever. Use a
unique key plus `restore-keys` so every run saves a fresh manifest and the next
run restores the most recent one:

```yaml
env:
  UNBLOCKED_COLLECTION_ID: "..."

steps:
  - uses: actions/cache@v4
    with:
      path: tmp/woods/unblocked_sync_manifest.json
      key: unblocked-sync-${{ env.UNBLOCKED_COLLECTION_ID }}-${{ github.run_id }}
      restore-keys: |
        unblocked-sync-${{ env.UNBLOCKED_COLLECTION_ID }}-
  - run: bin/rails woods:extract
  - run: bin/rails woods:unblocked_sync
    env:
      UNBLOCKED_API_TOKEN: "ubk_..."
      UNBLOCKED_REPO_URL: "https://github.com/your-org/your-repo"
```

### Buildkite

Buildkite has no native cache primitive. Note that plain
`buildkite-agent artifact download` is **scoped to the current build**: it
cannot restore a previous build's manifest on its own. Use the S3-backed
[cache plugin](https://github.com/buildkite-plugins/cache-buildkite-plugin)
(simplest), or resolve the last successful build's ID via the REST API and pass
`--build`:

```yaml
- label: ":trees: Woods → Unblocked"
  plugins:
    - cache#v1.7.0:
        manifest: Gemfile.lock          # any stable file; key below does the work
        path: tmp/woods/unblocked_sync_manifest.json
        restore: pipeline
        save: pipeline
  command:
    - bin/rails woods:extract
    - bin/rails woods:unblocked_sync
  branches: main
  env:
    UNBLOCKED_API_TOKEN: "ubk_..."
    UNBLOCKED_COLLECTION_ID: "..."
    UNBLOCKED_REPO_URL: "https://github.com/your-org/your-repo"
```

If you prefer the artifact API, the restore step must target a previous build
explicitly, e.g.
`buildkite-agent artifact download --build "$(previous_passed_build_id)" "tmp/woods/unblocked_sync_manifest.json" .`
where `previous_passed_build_id` queries the REST API for the last passed build
on the pipeline. Declaring `artifact_paths: tmp/woods/**/*` still uploads the
fresh manifest for free at the end of each run.

> **Concurrency:** two syncs racing (e.g. per-deploy CI on quick successive
> merges) can interleave manifest writes and put/delete calls. Gating this is
> the host pipeline's responsibility, set a Buildkite `concurrency_group` (or
> the GitHub Actions `concurrency:` key) on the sync step.

## Incremental Updates

The sync is incremental. A **sync manifest**
(`<output_dir>/unblocked_sync_manifest.json`) records the content hash and remote
document id of everything last pushed. On each run the exporter:

- **skips** documents whose built body hash is unchanged,
- **pushes** only new or changed documents,
- **deletes** documents whose source unit has disappeared.

Documents are upserted by URI. **Unreleased after 2.0.0:** the manifest keeps
separate repository/ref scopes; switching branches preserves the other branch's
documents. Ref segments are URL-encoded, including `#`, `?`, and `%`.

Every sync first inventories remote documents through all pages. A short page
is not proof of completion; malformed pages or repeated cursors stop before
writes. Individual remote documents without a non-empty string URI are skipped;
they provide no URI ownership evidence. This adds listing calls even when all
local documents are unchanged.
URIs are unique across the remote organization: Woods refuses a URI already
assigned to another collection instead of moving it.

A missing manifest rebuilds receipts for current documents but does **not**
adopt unrelated remote documents for deletion. Keep the manifest in a durable
CI cache. An unreadable, corrupt, or wrong-collection manifest requires recovery
from a known-good copy; setting force flags cannot recover ownership. Historical
entries adopted remotely with a null content hash are not deletion authority.

### Explicit ref migration

**Unreleased after 2.0.0:** unresolved owned receipts from a legacy manifest
leave sync incomplete. A URI prefix cannot prove the old ref: a slash can belong
to either a ref name or a source path. Woods never adopts or purges those
receipts by prefix. Select the known source ref with
`UNBLOCKED_MIGRATE_FROM_REF`, or review obsolete remote documents and their
legacy receipts for manual cleanup when there is no current replacement.
`UNBLOCKED_FORCE_PURGE` cannot bypass this ownership requirement.

Use migration only when retiring the old export scope, rather than publishing
two branches independently. Keep one writer per local manifest **and** remote
repository/ref scope; coordinate writers across worktrees and CI jobs.

```bash
UNBLOCKED_MIGRATE_FROM_REF=old-branch UNBLOCKED_DRY_RUN=1 bin/rails woods:unblocked_sync
UNBLOCKED_MIGRATE_FROM_REF=old-branch bin/rails woods:unblocked_sync
```

Preview reads the pinned index and local receipts, makes no remote requests or
local writes, and lists the proposed URI pairs. Review that list before applying.
Use the same source and target ref to migrate formerly unescaped special-character
URIs. Woods uploads replacements, persists successful receipts, then deletes
only recorded old IDs with unambiguous current replacements. This bounded
one-for-one cleanup does not require `UNBLOCKED_FORCE_PURGE`.

Interrupted migration resumes on the next sync of the target scope, even without
the environment variable. Missing ownership, changed remote IDs, missing
replacements, failed writes, and incomplete cleanup remain visible as incomplete;
Woods retains old copies until it can verify the replacement. It never infers
ownership from the collection listing. Records without matching replacement
units require operator review and manual cleanup. A historical bare URI shared
by multiple current units is ambiguous and is also retained for review; Woods
does not guess its old owner from the new lexically first identifier. Proven
one-to-one migrations also upload replacements outside the ordinary top-N cap. This is not an API-level
rename: remote IDs can change, so annotations attached to the old ID may not move.

Do not run an older Woods exporter against the upgraded version-2 manifest.
For rollback, stop sync and restore its pre-migration manifest together with the
corresponding remote state; restoring just the file cannot undo remote deletions.

Pair with `woods:incremental` to re-extract only changed files; the sync then
pushes only the documents whose content actually changed.

Before any API mutation, Woods reads and validates the complete published unit
set under one generation pin. Full and partial selection use actual unit types;
the GraphQL family includes its four published subtypes once. Standalone
`sync_type` and `sync_type_partial` calls perform the same preflight. Missing,
unreadable, or mismatched identities refuse before uploads, deletion, or
manifest writes. Preserve the error, validate and regenerate the index, then
retry. Force flags cannot bypass this check. Preflight reads all published
unit bodies, so local read cost and temporary memory scale with the index even
for a single-type sync. Custom readers must provide complete published
enumeration or complete per-bucket listings plus strict typed lookup.

### Escape hatches

- `UNBLOCKED_FORCE_FULL_SYNC=1`: re-push every document, ignoring the unchanged
  check (still uses the manifest for deletes). Use after a `DocumentBuilder`
  format change, which alters every body.
- `UNBLOCKED_FORCE_PURGE=1`: bypass the mass-deletion guard. The guard refuses
  to delete more than 30% of a manifest tracking ≥10 documents in one run, which
  protects against running the sync against a **partial index** (e.g.
  `woods:incremental` output in a fresh directory), where the current unit set
  is a small subset and an unguarded purge would wipe the collection.

  The guard also fires on *intentional* large removals: dropping a unit type
  from the sync set or a big codebase deletion can all legitimately exceed 30%. The refusal warning
  names the counts, if the deletions are expected, re-run once with
  `UNBLOCKED_FORCE_PURGE=1`. It does not bypass migration ownership checks.

## Troubleshooting

**"call budget exhausted for this run"**: The per-run cap
(`UNBLOCKED_DAILY_BUDGET`, default 1000) stopped the sync. This is a guard rail
against one run spending the whole allowance; it is **not** a reading of what
your token has left. The real 1,000 call/day limit is enforced server-side and
resets at midnight PST, so a fresh run starts the local counter at zero
regardless of what earlier runs (or other machines sharing the token) consumed.
Raise the cap if a legitimate cold sync needs more, or use a Team Access Token
if higher server-side limits are available.

**"Unblocked API error 401"**: Check your API token. Personal tokens are scoped
to your account; Team tokens access all team data.

**"collection_id is required"**: Set `UNBLOCKED_COLLECTION_ID` env var or
configure `config.unblocked_collection_id`.

**Documents not appearing in answers**: Documents take ~1 minute to become
available. Also verify the collection is enabled in your Unblocked data source
settings.

## Retries and Duplicates

A 429 is always retried, for any request, the server rejected it before doing any work. A 503 is different: an intermediary in front of Unblocked's API can synthesize a 503 for a request the origin already committed, so a blind retry risks creating a duplicate. The client only retries a 503 for **idempotent** requests (reads, and document upserts keyed by URI). Collection *creation* has no idempotency key, so a 503 on `create_collection` is raised immediately instead of retried. Document upserts and syncs are unaffected, they're idempotent by URI, so a 503 there retries normally.
