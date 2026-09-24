# Incremental Extraction

`woods:incremental` re-indexes only what changed. This page states the
correctness contract it is held to, the inventory of which path class triggers
which work, how to run the differential harness that enforces the contract, and
what is still out of scope.

Background: [#164](https://github.com/lost-in-the/woods/issues/164).

## The contract

> After any sequence of file create / modify / delete / rename operations, an
> index maintained purely by `extract_changed` is **indistinguishable from a
> cold `extract_all` of the same tree**.

Indistinguishable means: the same unit identifiers, the same per-unit JSON
content, the same `_index.json` per type, the same graph nodes / edges /
reverse edges / file map / type index / stats, PageRank recomputed, the
same manifest counts and `graph_analysis.json` — and, when flow
precomputation is enabled, the same `flows/flow_index.json`, the same
flow documents, and the same flow annotations on controller units.

Three differences are tolerated, and nothing else:

| Tolerated | Why |
|---|---|
| Wall-clock stamps (`extracted_at`, `generated_at`, and the digest over it) | A unit an incremental run correctly left alone keeps an older stamp. |
| Ordering inside a unit's `dependents` | Full extraction appends in extractor order, incremental in graph order. Same multiset. |
| PageRank beyond six decimal places | Iterative floating point accumulated in each run's registration order. Scores are compared as values; only the last bits are forgiven. |

The unit-file write skip ignores only Woods' top-level `extracted_at` stamp.
A nested metadata field with the same name is application data: changing it
rewrites the unit in both compact and pretty JSON output.

`graph_analysis.json` used to be a fourth row, tolerating list ordering. It no
longer is: the analyzer is order-independent and the oracle compares the file
exactly. Tolerating the ordering there meant the harness, the only test that
compares a full run against an incremental one, could not see the very
dependence the analyzer's determinism work existed to remove.

Graph targets use string identifiers even when an extractor emits a symbolic
external target such as `:http_api`. Full and incremental runs retain every
reverse dependency across JSON restoration and re-registration, including
contributions from units sharing an identifier under different types. Unit
dependency metadata retains its extractor-provided values. If an older version
already lost reverse dependencies on these targets, run a full extraction once
to restore them; loading the damaged graph cannot recover discarded entries.

This matters most for **incremental CI chains**: restore the previous graph,
run `woods:incremental` per merge. There, a unit that goes missing propagates
forward run over run instead of being erased by the next full rebuild.

## Exit behavior in CI chains

The task decides what to do before it extracts, and the exit code is part of
that decision — a green job that silently skipped the sync is exactly the
failure a CI chain cannot afford:

| Situation | Behavior |
|---|---|
| `CHANGED_FILES` is set | Comma-separated application-relative or contained absolute paths; normalized before filtering. Git is not consulted. |
| The git range resolves | Current behavior: extract the changed paths, or exit 0 with `No relevant files changed` when nothing relevant changed. |
| The range fails **and** a `:running` watch daemon maintains the index | Stand down with a printed reason, exit 0 — the daemon's start-up catch-up covers whatever changed. |
| The range fails otherwise | Actionable error naming the range, **exit 1**. |
| There is no `git` binary at all | Same two rows as above: the failure reads `git unavailable: …` and takes the daemon-coverage decision, rather than dying with an `Errno::ENOENT` backtrace. |

Changed paths are normalized lexically before the task's relevance filter:
trailing root slashes, duplicate separators and `.`/`..` segments do not create
separate changes or bypass matching. Paths outside `Rails.root` are excluded.
Missing files remain representable; symlinks are not resolved. The task-boundary
normalization and nested-application Git paths are unreleased after `2.0.0`;
check the installed revision before relying on them.

The range comes from `CI_COMMIT_BEFORE_SHA..CI_COMMIT_SHA` (GitLab),
`origin/$GITHUB_BASE_REF...HEAD` (GitHub Actions), or `HEAD~1` (default).
Whitespace-only CI variables are ignored; a nonempty GitLab before-SHA with
no current SHA compares against `HEAD`. Nonempty invalid revisions still fail.
An unresolvable range — a GitLab zero-SHA on a new branch, an unfetched base ref,
a shallow clone with no `HEAD~1` — cannot establish which files changed.
The task must not mistake that failed diff for an empty change set.
A degraded daemon covers nothing, so it
does not stand the run down. `WOODS_IGNORE_WATCH=1` removes daemon coverage
too — with it set, a failed range exits 1. A slim image with no `git` binary
resolves to the same decision rather than a raw `Errno::ENOENT`: the failure is
reported as `git unavailable: …`, so a daemon-covered tree still stands down
and an uncovered one still gets the remediation text.

Recovery choices, in the order they are worth trying:

1. Repair or provide the range: fetch the actual base ref and enough history
   to find its merge base, or correct the CI environment variables that build
   it. Depth two alone does not fetch a pull request's base branch.
2. Set `CHANGED_FILES` explicitly from your CI platform, bypassing git range
   resolution entirely.
3. Run a full `woods:extract` when the range cannot be repaired this run.

The diff itself is rooted at the extracted application (`git -C Rails.root`),
independently of the process working directory. Paths are application-relative
even when Rails lives below the repository root. Deletions and both sides of
renames within the application remain in the change set; sibling applications
are excluded. An explicit `WOODS_GIT_DIR`
selects that Git directory's HEAD for both the diff and manifest provenance.
For a linked worktree, use its worktree-specific directory within the complete
shared layout; selecting the shared root instead reads the primary checkout's
HEAD. See [worktree mount verification](TROUBLESHOOTING.md#git-directory-mounts-for-linked-worktrees).
Git-only changes may not trigger the source-file watcher; see the
[watcher limitation](WATCH_DAEMON.md#watcher-backends).

Named, source-defined app modules included by runtime models are tracked as concern units even
outside `concerns/` directories. Changing their source refreshes their includers,
including inlined code and callback analysis. Multiple runtime mixins sharing a source
file retain separate identities and refresh all their includers. Run a full extraction after upgrading
to populate these previously missing source mappings.

### GitHub Actions with an exact baseline

The restored index must describe the first commit in the selected diff.
A cache from an unrelated branch or older commit is not a valid baseline for
`HEAD~1` or a pull request's merge base. The recipe below restores only the
selected commit's exact cache key and runs full extraction on a cache miss.
It fetches complete history and the actual pull-request base ref; see
[checkout's history setting](https://github.com/actions/checkout#usage) and
[cache restore's exact-hit output](https://github.com/actions/cache/blob/v4/restore/README.md#outputs).

Adapt database setup, Ruby configuration, and the index path to the host app.
This example runs from a Rails app at the repository root. For a nested app,
set the run steps' working directory and adjust the cache path, hash paths,
and cache namespace to identify that app. Include every extraction-affecting
configuration input in the cache namespace; change it after a Woods upgrade
that needs a full baseline. An unverified or incomplete prior index needs a
full extraction even when a cache key matches.

```yaml
# .github/workflows/woods.yml
name: Update Codebase Index
on:
  push:
    branches: [main]
  pull_request:

jobs:
  index:
    runs-on: ubuntu-latest
    env:
      RAILS_ENV: test
      WOODS_IGNORE_WATCH: "1"
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Select the baseline commit
        id: base
        env:
          WOODS_BASE_REF: ${{ github.base_ref }}
          WOODS_BEFORE_SHA: ${{ github.event.before }}
        run: |
          if [ -n "$WOODS_BASE_REF" ]; then
            git fetch --no-tags origin "+refs/heads/$WOODS_BASE_REF:refs/remotes/origin/$WOODS_BASE_REF"
            base="$(git merge-base "origin/$WOODS_BASE_REF" HEAD)"
          elif [ -n "$WOODS_BEFORE_SHA" ] && git rev-parse --verify "$WOODS_BEFORE_SHA^{commit}" >/dev/null 2>&1; then
            base="$WOODS_BEFORE_SHA"
          else
            base=""
          fi
          printf 'sha=%s\n' "$base" >> "$GITHUB_OUTPUT"
      - name: Restore exactly that baseline
        id: index-cache
        if: steps.base.outputs.sha != ''
        uses: actions/cache/restore@v4
        with:
          path: tmp/woods
          key: woods-v2-app-${{ runner.os }}-${{ hashFiles('Gemfile.lock', 'config/initializers/woods.rb') }}-${{ steps.base.outputs.sha }}
      - name: Prepare the application database
        run: bin/rails db:prepare
      - name: Update the index
        env:
          WOODS_EXACT_BASELINE: ${{ steps.index-cache.outputs.cache-hit }}
          CI_COMMIT_BEFORE_SHA: ${{ steps.base.outputs.sha }}
          CI_COMMIT_SHA: ${{ github.sha }}
        run: |
          if [ "$WOODS_EXACT_BASELINE" = true ]; then
            bin/rails woods:incremental
          else
            bin/rails woods:extract
          fi
      - name: Validate the index
        run: bin/rails woods:validate
      - name: Save the validated current index
        uses: actions/cache/save@v4
        with:
          path: tmp/woods
          key: woods-v2-app-${{ runner.os }}-${{ hashFiles('Gemfile.lock', 'config/initializers/woods.rb') }}-${{ github.sha }}
```

There are deliberately no `restore-keys`: a partial match selects full
extraction. A first push, an unavailable before-SHA, or an absent baseline
cache also selects full extraction. A failed explicit PR-base fetch stops the
job with its Git error. The validated publication is saved under the current
checkout's SHA, never under the old baseline key.

For Docker CI, run database preparation and Woods tasks through the application
service, forward the selected CI variables into that container, and cache the
host-visible mount of the same index. Fetching the base only on a host whose
Git object store is absent from the container does not make that range usable
inside the application.

## Handled source errors and retry

Included in Woods `2.0.0`: when an incremental extraction or named refresh
records a handled consumer error (for example malformed locale or schedule
YAML), it raises `Woods::ExtractionError` before publishing. Empty output from
that failed consumer does not authorize replacing or deleting its last-good
units. The published generation and source provenance remain unchanged,
including when other files in the batch extracted successfully.

Fix the source error named in the extraction log, then retry the **complete
batch**, or the same named refresh. The watch daemon reports degraded and keeps
the failed batch pending for retry. An error on one file does not mark a later
successful file as failed, but the batch still cannot publish until all handled
errors are resolved. This does not change full extraction's existing tolerance
for handled consumer errors; its source-freshness report marks those scopes
unverified.

## What a run does, in order

`Extractor#extract_changed` is order-sensitive; each step exists because of the
step before it.

1. **Blast radius** from the *pre-change* graph, so dependents of a file that
   just disappeared still get re-extracted. Unbounded by default; see
   [Bounding the blast radius](#bounding-the-blast-radius).
2. **Reconcile changed paths.** Every changed path that still exists is handed
   to the file-based extractors that claim it (`PathDispatcher`), and units the
   path no longer produces are dropped. This is what indexes a file the index
   has never seen, and what removes definitions deleted from a surviving
   source file. Multi-file Rake tasks use wholesale reconciliation below.

   **Unreleased after 2.0.0:** changed-path candidates are collected and checked
   before registration or pruning. Moving an identity out of a surviving file
   works in either changed-path order only when completed extraction proves
   the old file no longer produces it and the new owner is unique. Failed or
   unsupported extraction cannot release an owner. For runtime classes, a
   complete eager load, an authoritative discovery inventory with one current
   class, and that class's canonical source location can establish the move.
   GraphQL's mixed runtime/file inventory does not grant this authority.
   Incomplete eager loading cannot establish a surviving-file ownership move;
   genuine simultaneous source owners still abort before publication.
3. **Re-extract the rest of the blast radius**: units whose own file did not
   change but which depend on something that did.
4. **Reconcile class-based types** against each extractor's
   `#discoverable_classes`, classes added since the last extraction, and
   classes the graph still holds that the set no longer contains. Exact by
   construction: it is the same discovery code a full extraction uses, so
   there is no path-to-constant guessing.
5. **Re-run whole-app extractors** whose trigger paths changed, replacing that
   unit type wholesale.
6. **Prune vanished units**, so anything steps 2–5 resurrected against a
   deleted file is swept in the same run rather than surviving as a ghost.
7. **Reconcile class-based types once more**, because pruning can un-know a
   class the first pass skipped: a class-based file moved between autoload
   directories with its constant unchanged still looks known when step 4 runs,
   so it is not re-extracted, and step 6 then removes it for its vanished old
   path. This pass re-adds it in the same run instead of waiting for some later
   run to notice. It skips everything else step 6 pruned (`except:`), because
   without a reload a constant outlives the file that defined it, otherwise
   deleting `app/models/user.rb` would prune `User` only for this pass to find
   it still in `ActiveRecord::Base.descendants` and re-register it against a
   path nothing can ever remove again. What separates the two shapes is
   loader-derived constant identity, not a textual class-name match: a pruned
   identifier is re-added only when the active Zeitwerk loader governs a
   changed file for exactly that constant (`cpath_expected_at` — the loader's
   inflector, ignores, and root namespaces decide — and the file declares it).
   A loader non-claim is authoritative: an unmanaged or declined path re-adds
   nothing. So a moved file whose governed constant matches qualifies, while
   another namespace's same-demodulized file, a mention in a comment or
   string literal, and an unrelated addition in the same batch do not.
   Idempotent when nothing was pruned.

8. **Reconcile source references** on supporting unreleased writers described in
   [constant source references](EXTRACTOR_REFERENCE.md#constant-source-references).
   Resolve cached candidates against the complete current typed unit registry,
   update callers' forward relationships, and refresh targets' reverse
   relationships. Unresolved candidates allow an unchanged caller to gain an edge
   when its target becomes indexed. Parsing is reused only when the captured
   source identity still matches.

Git enrichment uses the same eligibility checks in full and incremental runs:
existing app-owned files under `Rails.root`, excluding `vendor/`, `node_modules/`,
and framework/gem source units. Each typed unit resolves its own file history,
even when its identifier is shared by another type.

Then the second pass: `dependents` and `metadata.git` are refreshed on every
touched unit (the incremental equivalents of full extraction's phases 2 and 4),
type indexes are regenerated, the graph, `graph_analysis.json` and the
manifest are written, and — with flow precomputation enabled — the run's
controller delta gets the same flow treatment a full run gives (see
[Flow artifacts](#flow-artifacts)).

A run that changed nothing **does not rewrite the manifest**. The manifest
timestamp drives `woods_status.staleness_seconds`, and touching it after a no-op
would report the index as freshly synced when nothing was re-read.

## Bounding the blast radius

`incremental_blast_radius_depth` caps how many reverse hops step 1 walks.
`nil`, the default, keeps the unbounded transitive closure: every unit that
reaches the changed file, at any depth, is re-extracted.

The reason to cap it is cost. A unit's extracted content is mostly a function
of its own source and its own reflection, so on most graphs the deep half of
the closure re-derives bytes that do not change. On a 200-service chain in the
dummy app, one leaf edit re-extracts 200 units unbounded and 2 at a depth
of 1.

The reason the default is not capped is that "mostly" is not "always". An STI
grandchild reads its grandparent's reflection: `SportsCar < Car < Vehicle`
inherits `Vehicle`'s associations, validations and callback chain, and a
nested `has_many :through` resolves through the same kind of chain. The graph
records only the one-hop superclass reference each source file mentions, so
that grandchild sits two hops out while its content depends on hop zero. Set
the key on a tree you know has neither shape.

What the cap never affects is `dependents`. Edges change only when a unit is
re-extracted, and the run marks every target of a re-extracted unit's edges,
before and after registration, so a unit that gains or loses an inbound edge
is rewritten by the second pass whether or not the walk reached it.
`spec/integration/incremental_equivalence_spec.rb` holds a depth of 1 to
full-extraction equivalence, including that case.

## Dispatch inventory

### Per-file

Routed by `PathDispatcher.file_rules`. Rules reference each extractor's own
`*_DIRECTORIES` constant, so adding a directory there flows through
automatically.

| Path class | Extractor |
|---|---|
| `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases` | services |
| `app/jobs`, `app/workers`, `app/sidekiq` | jobs |
| `app/serializers`, `app/blueprinters`, `app/decorators` | serializers |
| `app/decorators`, `app/presenters`, `app/form_objects` | decorators |
| `app/managers` / `app/policies` / `app/validators` | managers / policies + pundit_policies / validators |
| `app/**/concerns/**/*.rb` | concerns |
| `app/models/**/*.rb` (outside `concerns/`) | poros, caching; concerns when runtime model inclusion confirms a mixin |
| `app/**/*.rb`, `lib/**/*.rb` (outside `concerns/`) | runtime model mixins also dispatch to concerns |
| `app/controllers/**/*.rb` | caching |
| `app/views/**/*.erb` | view_templates, caching |
| `config/locales/**/*.yml` | i18n |
| `config/initializers`, `config/environments` | configurations |
| `db/migrate/*.rb` (top level only) | migrations |
| `lib/**/*.rb` (outside `tasks/`, `generators/`) | libs |
| `spec/**/*_spec.rb`, `test/**/*_test.rb` | test_mappings |

A path can match several rules, `app/policies` is claimed by both
`PolicyExtractor` and `PunditExtractor`, `app/decorators` by both the
serializer and decorator extractors, and all matching rules run.

### Wholesale re-runs

`PathDispatcher.whole_app_rules` → `Extractor::WHOLE_APP_EXTRACTORS`. These
extractors need a complete runtime or directory view, even when a low-level
per-file reader exists. In an already-booted process re-running them is
cheap, which is what makes wholesale replacement the right shape.

| Trigger | Re-runs |
|---|---|
| `lib/tasks/**/*.rake` | rake_tasks (all definitions of every task) |
| `config/routes.rb`, `config/routes/**` | routes, engines, **and** controllers, mailers, components, view components, view templates |
| `Gemfile.lock` | engines, middleware, rails_source (gated by `include_framework_sources`) |
| `config/application.rb`, `config/initializers/**`, `config/environments/**` | middleware |
| `config/recurring.yml`, `config/sidekiq_cron.yml`, `config/schedule.rb` | scheduled_jobs |
| `app/models/**/*.rb` | state_machines |
| `app/**/*.rb` | events |
| `spec/factories/**`, `test/factories/**` | factories |
| `db/views/**/*.sql` | database_views |
| any `package.yml`, `packwerk.yml` | packages |

Four of these deserve a note:

- **Rake tasks merge definitions across files.** Any changed or deleted `.rake`
  file reruns the task extractor over all task files. Removing the primary
  definition preserves surviving definitions; removing a secondary definition
  drops its source and dependencies from the shared unit. After upgrading from
  the old per-file rules, run a full extraction to establish a source-freshness
  baseline with the new rule fingerprint.

- **Routes cascade.** `ROUTE_CONSUMER_EXTRACTORS` embed the route table, controllers write each action's routes into unit metadata and into the action
  chunks, and everything using `RouteHelperResolver` resolves navigation edges
  against it. The graph cannot express this, because a route unit depends *on*
  its controller, not the other way round, so walking dependents from
  `config/routes.rb` never reaches them.
- **Database views are wholesale, not per file.** Scenic keeps only the highest
  `_vNN` of each view, so pointing the per-file method at
  `db/views/foo_v01.sql` would index a version a full extraction drops.
- **Packages don't yet claim their members.** `PackageExtractor` (#280) only
  produces `package` units from `package.yml`; it does not annotate which
  package every other unit belongs to. A pack-resident file-based unit is not
  discovered by `PathDispatcher` through its package boundary today
  (follow-up B-175).

### Class-based types

Models, controllers, mailers, components, view components and channels are
**not** dispatched by path. They are reconciled against
`#discoverable_classes` on their own extractor, in **both** directions:
additions are that set minus the graph, removals are the graph minus that set.

For all six, `extract_all` is literally `discoverable_classes.map { … }.compact`,
so absence from the set is exactly "a full extraction would not produce this", the equivalence the incremental path is held to.

Removal is gated on the eager load having **completed**, and that gate carries
the whole safety argument:

- **A partial eager load.** The documented `NameError` fallback loads only
  `EXTRACTION_DIRECTORIES`, so descendants are known-incomplete and the
  difference would be most of the app. Deleting by the type is far worse than a
  stale unit, so a partial load removes nothing.
- **A constant outliving its file.** A resident daemon that has not reloaded
  still holds a deleted class as a descendant, so it is *in* the set and not
  stale, correct for that process. The subsequent reload is what makes it
  removable.

Without this, a class deleted from a file that still exists was never removed
at all: path-keyed deletion sees no missing path, and a class-based unit
records a *convention* path from its constant name, so a second model in one
`.rb` was never attributed to the file it actually lived in. The unit outlived
every subsequent incremental run.

The booted harness cannot cover that case. Zeitwerk unloads only the constant a
file is *expected* to define, so a class defined there as a side effect survives
the reload, stays in `descendants`, and the in-process full extraction the
oracle compares against emits it too, both sides agree, wrongly. The coverage
is in `spec/extractor_spec.rb`, driving the reconciler with a shrinking
discovery set.

### Runtime removals and bundle updates

Jobs discovered through `ApplicationJob.descendants` supplement the job-file
scan, but jobs are not part of `CLASS_BASED_DISCOVERY` removal reconciliation.
If a dynamically defined or gem-owned job disappears without a tracked source
path changing, its unit can survive subsequent incremental runs. A full
extraction in a fresh Rails process removes it; an in-process full extraction
can still see an old constant retained by that process (B-165).

After adding, removing, or updating bundled gems, boot the updated bundle in a
fresh process and run:

```bash
bundle exec rake woods:extract woods:validate
```

A `Gemfile.lock` change refreshes engines, middleware, and optional framework
sources. It does not refresh every gem-owned model, job, or other runtime unit.
Their recorded paths or metadata can remain stale, including absolute paths to
a removed gem version and paths under `vendor/`. A full extraction rebuilds
those units against the installed bundle (B-166).

An absent external source path can also mean the validator runs on a different
host or mount from extraction. Confirm the bundle and filesystem context before
rebuilding; a full run in one container does not make its gem paths visible on
another host. Validation warnings identify missing paths, but do not prove a
retained unit matches the currently installed gem when its path still exists.

### Deletion

- Paths named in the change set that no longer exist are **authoritative** for
  any unit type. This covers deleted models and the old side of a rename.
- A **sweep** over registered paths catches callers whose change set is
  incomplete (a git diff that omits deletions, a missed unlink, a branch
  switch). Being a heuristic, it is bounded twice:
  - **To paths a file rule claims.** Some units name a *nominal* path rather
    than a source file, `BehavioralProfile` names `config/application.rb`,
    which no rule claims.
  - **Away from class-based units entirely.** A class-based unit records a
    convention path when its source location can't be resolved, and that path
    need not exist. On Rails < 7.1, `ActiveRecord::SchemaMigration` and
    `ActiveRecord::InternalMetadata` are real `ActiveRecord::Base` descendants
    whose convention path (`app/models/active_record/schema_migration.rb`) no
    application has, and *is* claimed by the PORO rule, so the first bound
    doesn't cover it.

  Sweeping either would delete units a full extraction still produces.
- Only paths under `Rails.root` are considered either way: framework units point
  at gem paths, and an index restored from a CI artifact can carry paths
  produced under a different root.

## Flow artifacts

Everything in this section is gated on `precompute_flows` (default false).
The family has three parts: `flows/flow_index.json` (entry point → relative
document path), one document per controller action, and
`metadata[:flow_paths]` on the controller units.

A full extraction computes all three in one pass. An incremental run computes
them for its **delta**:

- **Re-extracted controllers** get their `metadata[:flow_paths]` back, their
  flow documents are re-assembled from the units on disk, and their entries
  replace whatever the previous index held for them — so an action removed
  from a re-extracted controller leaves the index even though the file still
  exists.
- **Controllers the run pruned** (deleted or renamed) leave the index
  entirely.
- **Untouched controllers' entries carry forward** from the previous
  generation, which payload seeding hardlinks into the run's payload
  directory.

Re-assembly is scoped further, because a flow document only reaches
`FlowPrecomputer::DEFAULT_MAX_DEPTH` units. The run walks the pre-change graph
to that same depth from its changed files; a re-extracted controller inside
that radius is re-assembled, and one outside it takes its
`metadata[:flow_paths]` back from the previous index without paying for the
assembly. Three cases opt out and re-assemble every re-extracted controller: a
targeted `Extractor#refresh`, which has no change set; a routes re-run, which
replaces every controller and moves the route a flow document carries without
touching any dependency edge; and a controller whose action set no longer
matches the previous index, which is how an action inherited from further up a
controller chain than the radius reaches still lands.

After the index is rewritten, a **dedicated flow-artifact sweep** removes
every `flows/` document no index entry references. It validates against
`flow_index.json` and is deliberately separate from the unit sweep: flows/
holds neither units nor an `_index.json`, so the unit sweep's in-memory
contract does not describe it. The whole refresh is **fail closed**: a
genuinely absent family (no `flows/` directory, or an empty one — typically
an index built while the gate was off) skips the refresh, but a family that
holds any artifact is authoritative. A missing `flow_index.json` among
documents, a corrupt one, a failed rehydration, write, patch, or sweep
raises, and the raise aborts the run **before** the generation publish —
no generation bump, the preceding generation stays resolved and readable.
`woods:validate` applies the same corruption rule (a populated family
without its index is an error) and never demands `_index.json` from
`flows/`. The full extraction path is fail closed too: `precompute_flows`
raises before the manifest and generation publish.

## Refreshing one extractor on demand

`Extractor#refresh` re-runs named extractors wholesale against an
already-booted app. Incremental runs reach the whole-app extractors by trigger
path; this reaches them by name, for a caller that already knows what went
stale.

```ruby
# After editing config/routes.rb, or from a resident process that just reloaded
Woods::Extractor.new(output_dir: "tmp/woods").refresh(:routes)
# => { types: [:routes, :controllers, :mailers, ...], touched: [...], unknown: [] }
```

```bash
bundle exec rake "woods:refresh[routes]"
bundle exec rake "woods:refresh[state_machines,factories]"
bundle exec rake woods:refresh          # lists the valid keys
```

Any extractor key works, not only the whole-app ones, `refresh(:models)` is a
legitimate way to re-derive every model after a schema change. A routes refresh
cascades to `ROUTE_CONSUMER_EXTRACTORS` for the reason given above. Like an
incremental run, `refresh` rewrites the graph, `graph_analysis.json`, the
affected type indexes and the manifest, so the result is durable.

## What a change actually requires: reload, restart, or neither

`Woods::ReloadPolicy` answers the question a resident process has to ask before
re-extracting: extraction reads the *runtime*, so "the file changed" is not the
same question as "what has to happen before re-reading it is worth anything".

| Action | Path classes | Why |
|---|---|---|
| `:reextract` | `config/locales/**`, `db/migrate/**`, `db/views/**`, `lib/tasks/**`, `spec/**`, `test/**`, `app/views/**` (non-Ruby), schedule files, `package.yml`, `packwerk.yml` | Woods reads bytes. No constant involved. |
| `:reload` | `app/**/*.rb`, `lib/**/*.rb` (outside `tasks/`, `generators/`), `config/routes.rb`, `config/routes/**` | An autoloaded constant changed; introspecting the old class would be a lie. |
| `:restart` | `Gemfile`, `Gemfile.lock`, `.ruby-version`, `.env*`, application/boot/environment files, initializers/environments/credentials, database/schema files, `config/settings*.yml`, and boot-captured service YAML | Captured at boot. Rails' reloader re-runs none of it. See the exact list below. |
| `:ignore` | everything else | Not extraction input. |

The `:restart` set is drawn generously on purpose. Rails' reloader replaces
autoloaded constants and nothing else, it does not re-run initializers,
re-resolve `Rails.application.config`, or rebuild the schema cache, all of
which Woods captures (`BehavioralProfile`, `MiddlewareExtractor`, model column
data). `rails/spring`'s staleness bugs came from under-scoping exactly this
set.

The exact additional boot-captured YAML set is `config/settings.yml`,
`config/settings/*.yml`, and `config/{cable,storage,sidekiq,puma,cache,queue}.yml`
(including `.yaml` spellings). Scheduled-job sources such as
`config/recurring.yml` and `config/sidekiq_cron.yml` remain `:reextract` inputs,
not restart triggers. `lib/woods/reload_policy.rb` is authoritative.

Two version-sensitive behaviours sit *behind* the classification rather than in
it, and belong to whoever implements the reload step:

- `ActiveSupport::DescendantsTracker` internals changed across Rails 6.0–8.x, so
  a reload can leave stale entries in a descendants set. Discovery-based
  extraction must re-read descendants *after* the reload completes, never
  across it.
- A schema change needs `reset_column_information` plus schema-cache
  invalidation to become visible. It is classified `:restart` rather than
  `:reload` because getting that right in-process is subtle and schema changes
  are rare.

`Watch::Daemon` consumes the policy on every cycle: `classify_all` decides what
the batch demands, and `paths_requiring(:restart)` names the offending paths in
the restart message a supervisor sees. See `docs/WATCH_DAEMON.md`.

## Running the differential harness

`spec/integration/incremental_equivalence_spec.rb` is the oracle. It boots the
`spec/dummy` app against a tmpdir copy, applies randomized
create/modify/delete/rename sequences, and compares the maintained index to a
cold full extraction at every step. It runs in CI on every Rails-matrix row.

```bash
# CI defaults: 60 operations x 3 seeds
WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile \
  bundle exec rspec spec/integration/incremental_equivalence_spec.rb

# Soak run
WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile \
  WOODS_DIFF_OPS=1000 WOODS_DIFF_SEEDS=1,2,3,4,5 \
  bundle exec rspec spec/integration/incremental_equivalence_spec.rb -e randomized

# When a truncated delta isn't enough to see what moved
WOODS_DIFF_BRIEF=4000 ...
```

Seeds are fixed, so a failure reproduces. `spec/support/index_comparison.rb`
owns the definition of "the two indexes agree" and documents every exclusion.

**Run it before and after any change to the incremental path.**

## Profiling fixed costs

Set `WOODS_PROFILE=1` to time extraction phases. Git enrichment and unit JSON
finalization are separate from incremental re-extraction; runtime discovery,
whole-app reruns and pruning appear under `reconciliation`. `payload sync`,
`publish` (the generation pointer write), and `payload prune` (retention) are
separate, additive phases. Older versions included sync and retention inside
`publish`, so do not sum those older lines without subtracting nested sync.

`[profile total]` reports time inside the extraction call, including setup and
failed runs. It is not another phase to sum. Compare it with phase durations
to find unaccounted work; each line rounds to hundredths of a second. Rails
boot, Bundler and watch reload work outside the call require separate wall
measurements. Do not infer that all unaccounted time is boot.

Both full and incremental runs currently seed the prior payload. Cloning uses
per-file hardlinks (or copies where links are unsupported); updated files are
replaced atomically, preserving previous generations. Full-run carry-forward
and generation retention remain unchanged. The seed walker classifies each entry
once, avoiding duplicate file metadata lookups; it still links each file
separately. Generation directories remain independent, so pruning an old generation cannot remove a newer one's files.
Compare repeated runs on the actual index filesystem before attributing latency
to extraction or changing the index layout.

For a repeatable component comparison from a source checkout:

```bash
# BENCH_ROOT is an existing scratch parent on the index filesystem.
# The script creates and removes only its own temporary directory there.
BENCH_ROOT=/path/on/index/filesystem WOODS_SOURCE=/path/to/baseline \
  ruby bench/payload_seed.rb
BENCH_ROOT=/path/on/index/filesystem WOODS_SOURCE=/path/to/candidate \
  ruby bench/payload_seed.rb
```

The benchmark clones 8,335 synthetic 2 KiB files across 35 directories, checks
file counts and bytes outside timing, and reports seven samples plus medians.
This measures the seed component only; it does not boot Rails or establish an
end-to-end host improvement. Filesystem metadata latency and the copy fallback
can dominate differently from local hardlink results. A first full extraction
has no previous payload, so include a repeated full run when measuring seed cost.
Full seeding also preserves on-demand framework units when framework extraction
is disabled, and non-JSON files in existing type directories; dropping the seed
wholesale would change that behavior.

### Choosing full versus incremental for CI

Measure repeated full and representative-day incremental runs with
`WOODS_PROFILE=1` on the same resulting application tree, configuration and index
filesystem. Restore the same baseline index before each incremental trial;
otherwise a second trial may be a no-op. Include Rails boot in both wall times
when comparing separate task invocations, and compare resident watcher cycles
separately. Validate each resulting index with `woods:validate`.

Use full extraction for that workload when its median wall time is no greater
than the representative incremental run. There is no universal changed-file
threshold: shared dependencies and whole-app extractor triggers change the work
per file. Re-measure after substantial application or Woods changes. A fast leaf
edit does not establish that a day of commits is below the crossover.

## Boundaries and open work

- **Reloaded deletion is supported.** The resident watcher reloads changed
  constants before discovery-set reconciliation, so deleting a class-backed
  file removes its unit. A caller using the lower-level incremental API without
  the watcher must ensure the Rails runtime has been reloaded first.
- **Identifier identity is typed.** Units of different types that share an
  identifier remain separate graph nodes. Two source files that produce the
  same type+identifier are not representable; full extraction fails closed
  with both source paths instead of publishing a glob-order tie-break (resolved
  B-063). Same-file re-derivation remains a legitimate deduplication case.
  **Unreleased after 2.0.0:** incremental extraction and targeted refresh enforce
  the same collision refusal (#561), preserving the prior published generation.
  Distinct unit types in separate extractor directories remain independent.
  A retained source can move when the old file is confirmed absent and the new
  file exists; two conflicting sources produced within one run always refuse.
  Complete wholesale replacement can relocate an owner, such as framework
  source after a gem upgrade. Partial runtime discovery cannot grant that authority.
  Correct the producer or declarations, then retry the complete failed batch.
  A watcher retains failed paths and reports degraded status until corrected.
- **Class-based units are never swept**: see [Deletion](#deletion) above for
  why (the `SchemaMigration`/`InternalMetadata` convention-path case).
  Deleting a class-based unit therefore requires either the caller naming the
  path or the discovery-set reconciliation above; the sweep never infers it.
- **Git metadata for untouched units.** An incremental run refreshes
  `metadata.git` on the units it wrote. A unit nothing touched keeps the git
  metadata from the last run that did, which goes stale as commits land on
  other files. The same holds for the node attributes `commit_count` and
  `change_frequency` that feed the `volatile_dependencies` report.
- **Snapshots stay full-extraction-only.** They hash the full unit set, and an
  incremental run only holds changed units in memory.
- **A divergence floor is still worth keeping.** Incremental correctness is a
  ratchet, not a proof: schedule a periodic full extraction and gate on
  `woods:validate` so any undiscovered drift has a bounded lifetime.
- **Phases 1–4** of #164, a public single-extractor re-run API
  (`Extractor#refresh`), the resident `woods:watch` daemon, an MCP freshness
  contract, and multi-worktree operation, all landed alongside this work
  (B-064, resolved). `docs/WATCH_DAEMON.md` covers them, including the parts
  that remain unmeasured.

## Source-reference baseline and upgrades

**Unreleased after 2.0.0; planned for 2.1.** Older indexes remain readable.
Writers with the [source-reference expansion](EXTRACTOR_REFERENCE.md#constant-source-references)
require one full `bin/rails woods:extract` before incremental extraction or
targeted refresh can update an older index without its reference cache. Follow
with `bin/rails woods:validate` using the application's normal task launcher.

`source_references.json` is internal writer state in the published payload.
Preserve it with the complete payload when copying an index. Missing/incompatible
cache state or unverified retained source stops publication with a full-extraction
diagnostic. Reconstruct it by running a full extraction; do not manufacture a
cache or delete it to bypass the check. The preceding generation remains active.
The watcher preserves failed batches but does not automatically repair this
baseline: establish the full baseline before resuming incremental maintenance.

This also tightens scoped refreshes: if a retained reference-bearing Ruby unit's
source changed outside the selected batch, the writer refuses to combine its old
runtime facts with references resolved from the new source. For example,
`woods:refresh[events]` cannot adopt an edited service unit. The prior generation
stays active and can report `drifted`; use a full extraction to establish a
consistent baseline. Omitted non-reference inputs, such as a view changed before
capture, retain the existing per-consumer freshness behavior.

A source change during reference analysis or final verification also prevents
publication. Correct source errors and retry the complete batch against a stable
tree. Reference-only edge updates do not refresh a retained unit's runtime
metadata, extraction timestamp or Git history.
