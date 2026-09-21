# Reproducing the booted Rails fixtures

These are development experiment helpers. They do not ship in Woods' runtime,
send inference requests, publish Git commits, or change the source testbed.
The candidate applications and all writes live under an explicit output path.

The four original pairs cover callback bypass, inherited authorization,
transaction/job timing, and database uniqueness. The eight additional pairs
cover nil memoization, default-scope visibility, cache invalidation, unbatched
loading, association preloading, tenant lookup, ineffective assertions, and
atomic writes. Each pair has a demonstrated defect and a control for its stated
contract; controls are not claims that an entire application is bug-free.

## Prerequisites

- Check out Woods and the public Woods testbed repository. The testbed must
  include its tracked `apps/rails-8.0-large` application, including the Canopy
  migrations and `spec/rails_helper.rb`.
- Use Python 3.9 or later, Git, and Docker. No host Rails installation is needed.
- Have the testbed's Rails 8 image and populated bundle volume available. The
  defaults are `woods-testbed-rails-8.0-large:latest` and
  `woods-testbed-bundle-rails-8-large`; both can be overridden. Follow the
  testbed's build/bundle setup if these caches are not already available.
- The image must provide Ruby matching the copied Gemfile, and the cached gems
  must satisfy its dependencies plus the chosen Woods checkout. The recorded
  experiment used Ruby 3.3.1 and Rails 8.0.5.1. The bootstrap runs
  `bundle lock --local` and `bundle check`; it fails if the cache is incomplete
  instead of downloading or updating dependencies remotely.

Docker runs use `--pull=never`, and the bundle is mounted read-only. A template
`Gemfile.lock`, when present, is copied into the disposable application;
`--bundle-lock /path/to/Gemfile.lock`
can supply a separately preserved lock. Only that copy can change during local
resolution. Image tags and cached dependency versions can vary, so compare
runtime versions and the recorded lockfile hash when reproducing results.

## Build and verify all twelve pairs

From the Woods checkout, choose source paths and a new output directory:

```bash
woods_root="$PWD"
testbed_root="/path/to/woods-testbed"
fixture_output="$(mktemp -d)"

PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/build_original_pairs.py \
  --testbed-root "$testbed_root" \
  --woods-root "$woods_root" \
  --output "$fixture_output/original" \
  --jobs 2

PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/build_extra_pairs.py \
  --template "$fixture_output/original/base" \
  --woods-root "$woods_root" \
  --output "$fixture_output/extra" \
  --jobs 2
```

Add `--docker-command 'sudo -n docker'` to both commands if that is how Docker
is accessed on your machine. `--image` and `--bundle-volume` override the cache
names. The extra builder depends only on the freshly produced `original/base`
directory and checked-in helper source; it has no dependency on an old `/tmp`
application, ignored collector, personal home-directory path, API credential,
or historical inference capture.

The original builder copies tracked application files, never the original
database, logs, generated index, untracked local configuration, or secrets. It
creates a new SQLite database with `db:prepare` and the testbed's demo seeds.
Each candidate gets a separate copy of that database and an independent Git
repository. Extra fixtures copy this disposable baseline, add their tables,
then construct their own isolated candidates.

Both builders refuse to overwrite a prepared base. To replay an existing bank,
provide the same paths and add `--run`; use `--only ID ...` for selected cases.
`--prepare` alone creates the fixtures without executing their oracles. Each
run restores a baseline database and clears only its candidate's generated
index before extraction. It refuses a changed Woods HEAD or a dirty candidate.
Replaying updates files under that output directory: use a new directory when
preserving frozen experiment captures.

## Evidence and private results

Each output contains:

- `cases.json`: opaque case IDs, proposed diffs, supporting source paths,
  candidate commits, pair assignments, private labels, and target questions.
- `fixture-freeze.json`: source revision and holdout assignment recorded before
  any inference. The extra holdouts are tenant lookup, test effectiveness, and
  atomic writes; the complete pair is held out.
- `preparation-receipt.json`: source/dependency provenance and exact bootstrap
  command.
- `results/<id>-evidence.json`: selected source, source hashes, runtime units,
  relationships, generation, checked-out commit, and deep freshness result.
- `results/<id>-oracle.json`: private executable outcomes and expected labels.
- `results/<id>-run.json` and `results/<id>.log`: exact Docker commands, stage
  order, status, and raw output. The test-effectiveness pair also saves ordinary
  and mutant RSpec logs.

Every extraction invokes:

```bash
bundle exec ruby -I/woods-gem/lib /woods-gem/exe/woods-extract full
```

This captures the source-input boundary before Rails boots. An extraction rake
task invoked after application boot cannot provide the same freshness evidence.
The collector requires deep `current` status and a clean matching candidate
revision before saving evidence. Schema migration may create a follow-up Git
commit: original cases keep the proposed `head` and record the resulting
`materialized_head` separately. Its initial source freeze and final materialized
case-list hash are separate provenance records.

Only candidate diffs, stated intent, and selected evidence fields should enter
review requests. Never serialize `cases.json`, private oracle files, logs, or
freeze labels wholesale into model state. Ordinary application specs are valid
source evidence; their execution outcomes are private experiment results.

These commands reconstruct the mechanisms with newly recorded provenance.
They do not reproduce historical Git hashes, timing, request bytes, or provider
answers. Replaying an inference comparison requires its separately preserved
request/response and label ledgers. It does not require rebuilding the fixtures,
and rebuilding does not authorize another provider call.

The additional test-effectiveness pair intentionally includes an easy, vacuous
assertion to exercise the bank's `test_cannot_fail` question. Its mutation oracle
demonstrates the consequence. Treat that pair as controlled mechanism coverage,
not a measure of arbitrary production review difficulty. The default-scope
control deliberately retains a legitimate scope; fact/convention questions
about its presence are distinct from the demonstrated visibility defect.
