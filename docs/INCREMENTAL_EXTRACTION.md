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
reverse edges / file map / type index / stats, PageRank recomputed, and the
same manifest counts and `graph_analysis.json`.

Three differences are tolerated, and nothing else:

| Tolerated | Why |
|---|---|
| Wall-clock stamps (`extracted_at`, `generated_at`, and the digest over it) | A unit an incremental run correctly left alone keeps an older stamp. |
| Ordering inside a unit's `dependents` | Full extraction appends in extractor order, incremental in graph order. Same multiset. |
| Ordering inside `graph_analysis.json` lists | Emitted in graph-registration order; membership is what those lists mean. |

This matters most for **incremental CI chains** — restore the previous graph,
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
3. **Re-extract the rest of the blast radius** — units whose own file did not
   change but which depend on something that did.
4. **Reconcile class-based types** against each extractor's
   `#discoverable_classes`, catching classes added since the last extraction.
   Exact by construction: it is the same discovery code a full extraction uses,
   so there is no path-to-constant guessing.
5. **Re-run whole-app extractors** whose trigger paths changed, replacing that
   unit type wholesale.
6. **Prune vanished units** last, so anything steps 2–5 resurrected against a
   deleted file is swept in the same run rather than surviving as a ghost.

Then the second pass: `dependents` and `metadata.git` are refreshed on every
touched unit (the incremental equivalents of full extraction's phases 2 and 4),
type indexes are regenerated, and the graph, `graph_analysis.json` and the
manifest are written.

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

A path can match several rules — `app/policies` is claimed by both
`PolicyExtractor` and `PunditExtractor`, `app/decorators` by both the
serializer and decorator extractors — and all matching rules run.

### Wholesale re-runs

`PathDispatcher.whole_app_rules` → `Extractor::WHOLE_APP_EXTRACTORS`. These
extractors have no per-file entry point: they introspect the runtime or scan a
whole directory in one pass. In an already-booted process re-running them is
cheap, which is what makes wholesale replacement the right shape.

| Trigger | Re-runs |
|---|---|
| `config/routes.rb`, `config/routes/**` | routes, engines, **and** controllers, mailers, components, view components, view templates |
| `Gemfile.lock` | engines, middleware |
| `config/application.rb`, `config/initializers/**`, `config/environments/**` | middleware |
| `config/recurring.yml`, `config/sidekiq_cron.yml`, `config/schedule.rb` | scheduled_jobs |
| `app/models/**/*.rb` | state_machines |
| `app/**/*.rb` | events |
| `spec/factories/**`, `test/factories/**` | factories |
| `db/views/**/*.sql` | database_views |

Two of these deserve a note:

- **Routes cascade.** `ROUTE_CONSUMER_EXTRACTORS` embed the route table —
  controllers write each action's routes into unit metadata and into the action
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
`#discoverable_classes` on their own extractor. Only additions go through
reconciliation; removals go through the deletion sweep, because a constant
outlives its file in a process that has not reloaded, and treating "absent from
descendants" as deletion would make a partial eager load erase whole types.

### Deletion

- Paths named in the change set that no longer exist are **authoritative** for
  any unit type. This covers deleted models and the old side of a rename.
- A **sweep** over registered paths catches callers whose change set is
  incomplete (a git diff that omits deletions, a missed unlink, a branch
  switch). The sweep is limited to paths a file rule claims, because some units
  point at a *nominal* path — `BehavioralProfile` names
  `config/application.rb`, and a class-based unit falls back to a convention
  path when its source location can't be resolved. Sweeping those would delete
  units a full extraction still produces.
- Only paths under `Rails.root` are considered either way: framework units point
  at gem paths, and an index restored from a CI artifact can carry paths
  produced under a different root.

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

## Limits and open work

- **Class-based deletion needs a reload.** The harness compares two extractions
  in the *same booted process*, which isolates incremental maintenance from
  Rails reloading. Deleting a model file leaves the constant loaded, so a
  full extraction in that process still emits it. Reload semantics are phase 2
  of #164.
- **Identifier collisions.** The graph keys nodes on the bare identifier, so two
  units of different types sharing one collapse onto a single node (backlog
  B-062), and two files defining the same constant tie-break differently in
  full vs incremental extraction (B-063). Both pre-date this work; the harness
  side-steps them by giving each generated artifact family its own name prefix.
- **Git metadata for untouched units.** An incremental run refreshes
  `metadata.git` on the units it wrote. A unit nothing touched keeps the git
  metadata from the last run that did, which goes stale as commits land on
  other files.
- **Snapshots stay full-extraction-only.** They hash the full unit set, and an
  incremental run only holds changed units in memory.
- **A divergence floor is still worth keeping.** Incremental correctness is a
  ratchet, not a proof: schedule a periodic full extraction and gate on
  `woods:validate` so any undiscovered drift has a bounded lifetime.
- **Phases 1–4** of #164 — a public single-extractor re-run API, the resident
  `woods:watch` daemon, an MCP freshness contract, and multi-worktree operation
  — are tracked in backlog B-064.
