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

`graph_analysis.json` used to be a fourth row, tolerating list ordering. It no
longer is: the analyzer is order-independent and the oracle compares the file
exactly. Tolerating the ordering there meant the harness, the only test that
compares a full run against an incremental one, could not see the very
dependence the analyzer's determinism work existed to remove.

This matters most for **incremental CI chains**: restore the previous graph,
run `woods:incremental` per merge. There, a unit that goes missing propagates
forward run over run instead of being erased by the next full rebuild.

## What a run does, in order

`Extractor#extract_changed` is order-sensitive; each step exists because of the
step before it.

1. **Blast radius** from the *pre-change* graph, so dependents of a file that
   just disappeared still get re-extracted.
2. **Reconcile changed paths.** Every changed path that still exists is handed
   to the file-based extractors that claim it (`PathDispatcher`), and units the
   path no longer produces are dropped. This is what indexes a file the index
   has never seen, and what lets a task removed from a multi-task `.rake` file
   actually go away.
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
   path nothing can ever remove again. What separates the two shapes is the
   filesystem: a pruned identifier is re-added only when a still-existing file
   in the change set actually declares its class — a moved file qualifies, a
   deleted one (and an unrelated addition in the same batch) does not.
   Idempotent when nothing was pruned.

Then the second pass: `dependents` and `metadata.git` are refreshed on every
touched unit (the incremental equivalents of full extraction's phases 2 and 4),
type indexes are regenerated, the graph, `graph_analysis.json` and the
manifest are written, and — with flow precomputation enabled — the run's
controller delta gets the same flow treatment a full run gives (see
[Flow artifacts](#flow-artifacts)).

A run that changed nothing **does not rewrite the manifest**. The manifest
timestamp drives `woods_status.staleness_seconds`, and touching it after a no-op
would report the index as freshly synced when nothing was re-read.

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
| `app/models/**/*.rb` (outside `concerns/`) | poros, caching |
| `app/controllers/**/*.rb` | caching |
| `app/views/**/*.erb` | view_templates, caching |
| `config/locales/**/*.yml` | i18n |
| `config/initializers`, `config/environments` | configurations |
| `db/migrate/*.rb` (top level only) | migrations |
| `lib/tasks/**/*.rake` | rake_tasks |
| `lib/**/*.rb` (outside `tasks/`, `generators/`) | libs |
| `spec/**/*_spec.rb`, `test/**/*_test.rb` | test_mappings |

A path can match several rules, `app/policies` is claimed by both
`PolicyExtractor` and `PunditExtractor`, `app/decorators` by both the
serializer and decorator extractors, and all matching rules run.

### Wholesale re-runs

`PathDispatcher.whole_app_rules` → `Extractor::WHOLE_APP_EXTRACTORS`. These
extractors have no per-file entry point: they introspect the runtime or scan a
whole directory in one pass. In an already-booted process re-running them is
cheap, which is what makes wholesale replacement the right shape.

| Trigger | Re-runs |
|---|---|
| `config/routes.rb`, `config/routes/**` | routes, engines, **and** controllers, mailers, components, view components, view templates |
| `Gemfile.lock` | engines, middleware, rails_source (gated by `include_framework_sources`) |
| `config/application.rb`, `config/initializers/**`, `config/environments/**` | middleware |
| `config/recurring.yml`, `config/sidekiq_cron.yml`, `config/schedule.rb` | scheduled_jobs |
| `app/models/**/*.rb` | state_machines |
| `app/**/*.rb` | events |
| `spec/factories/**`, `test/factories/**` | factories |
| `db/views/**/*.sql` | database_views |

Two of these deserve a note:

- **Routes cascade.** `ROUTE_CONSUMER_EXTRACTORS` embed the route table, controllers write each action's routes into unit metadata and into the action
  chunks, and everything using `RouteHelperResolver` resolves navigation edges
  against it. The graph cannot express this, because a route unit depends *on*
  its controller, not the other way round, so walking dependents from
  `config/routes.rb` never reaches them.
- **Database views are wholesale, not per file.** Scenic keeps only the highest
  `_vNN` of each view, so pointing the per-file method at
  `db/views/foo_v01.sql` would index a version a full extraction drops.

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

After the index is rewritten, a **dedicated flow-artifact sweep** removes
every `flows/` document no index entry references. It validates against
`flow_index.json` and is deliberately separate from the unit sweep: flows/
holds neither units nor an `_index.json`, so the unit sweep's in-memory
contract does not describe it. The sweep skips when the index is missing or
does not parse — with nothing to validate against, deleting every document
would be worse than keeping orphans, and the next full extraction rebuilds
the family. `woods:validate` validates the family by the same reference rule
(missing or malformed documents are errors), and never demands `_index.json`
from `flows/`.

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
| `:reextract` | `config/locales/**`, `db/migrate/**`, `db/views/**`, `lib/tasks/**`, `spec/**`, `test/**`, `app/views/**` (non-Ruby), schedule files | Woods reads bytes. No constant involved. |
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

## Boundaries and open work

- **Reloaded deletion is supported.** The resident watcher reloads changed
  constants before discovery-set reconciliation, so deleting a class-backed
  file removes its unit. A caller using the lower-level incremental API without
  the watcher must ensure the Rails runtime has been reloaded first.
- **Identifier identity is typed.** Units of different types that share an
  identifier remain separate graph nodes. Two source files that redefine the
  same Ruby constant can still tie-break differently between full and
  incremental extraction (B-063); that source tree is already ambiguous, and
  the differential harness avoids it.
- **Class-based units are never swept**: see [Deletion](#deletion) above for
  why (the `SchemaMigration`/`InternalMetadata` convention-path case).
  Deleting a class-based unit therefore requires either the caller naming the
  path or the discovery-set reconciliation above; the sweep never infers it.
- **Git metadata for untouched units.** An incremental run refreshes
  `metadata.git` on the units it wrote. A unit nothing touched keeps the git
  metadata from the last run that did, which goes stale as commits land on
  other files.
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
