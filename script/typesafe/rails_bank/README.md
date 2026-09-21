# Full Rails question-bank experiment

This source-checkout experiment runs the supplied **204-question Rails bank**
alongside the retained six-question review baseline. It is an experiment runner
over frozen fixture evidence, not an installed-app pre-push command. It does not
ship in the Woods gem, change MCP, install hooks, gate merges, or create an app UI.
The older tools in the parent directory remain unchanged. See the
[completed results](../../../docs/design/plans/2026-09-21-typesafe-full-bank-results.md)
for positive signals, interpretation limits and the additional stale-transfer probe.

The [source bank](source-question-bank.md), [catalog](catalog.json),
[import audit](bank-corrections.md), and [prospective protocol](protocol.md)
separate author-provided questions from this implementation's metadata choices.
All 204 questions retain their text and levels/options: 185 Nouls, 16 Scores,
3 Choices. Reviewer headings organize the report; names are not treated as
independent reviewers. No persona prefixes were added to the inference text.

## Reproduce the experiment

Read [fixture reproduction](fixtureREADME.md) to build twelve executable Rails
defect/control pairs in disposable output directories. The helpers accept explicit
Woods/testbed paths and use cached Docker images/gems. No private app is required.
The examples below assume its `fixture_output` shell variable remains set.

```bash
trial_output="$(mktemp -d)"

PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/runner.py prepare \
  --root "$trial_output" \
  --prior "$fixture_output/original" \
  --extra "$fixture_output/extra"
```

Inspect `preflight.json`, one request in `requests/`, its `packets/` state and
`ledgers/` receipt before inference. Preparation validates captured deep-freshness and clean-revision receipts, plus
serialized source hashes, while keeping oracle labels outside provider input.
Collectors check the live application when capturing those receipts; preparation
does not recheck a later live worktree. Both arms receive the same state bytes. All 204 questions are
sent when the request fits; questions split with complete state if needed.

Only capture accesses the provider. Use an already populated `TYPESAFE_API_KEY`
environment variable, or load it once through a credential command:

```bash
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/runner.py capture \
  --root "$trial_output" \
  --credential-command op read 'op://VAULT/ITEM/password'
```

The credential command is executed as an argument array, not through a shell.
Its output stays in process memory, with one lookup per complete capture. Do not
put the key value itself into command arguments. Existing captures are never
overwritten. Development and then holdout requests run with three workers;
explicit repeats are not retries. HTTP failures remain visible and billable usage
is retained whenever valid. Redirects and automatic environment proxies are
disabled for the credential-bearing provider request.

```bash
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/runner.py summarize \
  --root "$trial_output"
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/presentation.py \
  --root "$trial_output"
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/metrics.py \
  --root "$trial_output"
```

The presentation step reproduces the explicitly **post-capture** September 21
correction: Tests/Views section applicability follows changed file paths. The
initial reports/summary remain preserved, and `presentation-audit.json` explains
the correction. A missing test-only premise is not a pass. Unsupported path
conventions and Observability's conflicting section/question scope need further
application-specific work; this interpreter is validated only on these fixtures.
Do not rerun summarization over a versioned presentation; use a fresh analysis
directory to preserve the derivation you already have.

## Optional downstream reviewer comparison

After inspecting the report, the following commands create six fresh reviewer
sessions: ordinary, baseline-assisted and bank-assisted, twice each. They invoke
the locally configured Codex CLI/model; record that configuration with results.
They cost reasoning-model usage separately from Jev.

```bash
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/reviewers.py prepare \
  --root "$trial_output"
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/reviewers.py run \
  --root "$trial_output"
```

The completed trial also has a separate **posthoc delivery/recovery comparison**:

```bash
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/reviewers.py prepare \
  --root "$trial_output" --delivery-audit
PYTHONDONTWRITEBYTECODE=1 python script/typesafe/rails_bank/reviewers.py run \
  --root "$trial_output" --delivery-audit
```

This creates `reviewers-delivery/`, preserving `reviewers/`. It asks for one
candidate per tool call and enough output space, and permits reopening a candidate
without charging a second distinct-inspection slot. Banks, evidence, seeds and
budgets stay unchanged. Do not pool the two experiments: complete recorded tool
output still does not prove complete client display.

Each has at most eight distinct deep inspections, a 180-second prompt budget and
a 210-second external cutoff. All conditions can access the same evidence; the
assisted conditions can begin with the shortlist. Full-bank inspections also
include the detailed report. No oracle labels/results go to the reviewers.
Inspect command traces for output truncation and boundary compliance. Aggregate
usage is not enough to reconstruct token usage at the first finding; event timing
can identify when a supported finding was first emitted. A reviewer listing no
unassessed IDs does not override the actual inspection ledger.

## Interpretation and known limits

- Nouls are individual judgments; direction is explicit. Scores are displayed as
  distinct dimensions. Their values are never defect probabilities. Choices,
  facts and conventions are retained separately.
- The trial's maximum-Noul candidate ordering is an implementation choice,
  **not a requirement of the supplied handoff**. High pattern/style answers can
  overwhelm correctly separated mechanism questions. Measure this composition
  separately from the usefulness of individual bank questions.
- Catalog defaults classify several debatable pattern/convention questions as
  defects. The import audit records that choice rather than silently repairing
  the supplied semantics. Use the raw signals to inspect this limitation.
- Evidence status records declared requirements and selected source scope, not
  proof that every implicit premise of a question is satisfied. Whole-app
  callers, sibling analogies, git history and many searches are not supplied.
- The source bank's nil-memoization wording and Rails cache-versioning behavior
  were not reliably recognized in this trial. They remain preserved as misses.
- Fixtures are curated and often easy. The test-effectiveness fixture contains
  a deliberately vacuous assertion. They do not represent a production monolith,
  alternate databases/framework versions, or autonomous evidence selection.
- A passing control oracle certifies its planted contract only. Incidental bank
  alarms need independent investigation before calling them bugs or false alarms.

## Validation and artifact retention

```bash
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover \
  -s script/typesafe/rails_bank -p 'test_*.py'
bin/rspec spec/development/typesafe
```

The catalog tests reconstruct every original row. Runner tests cover malformed
responses, rounding, lost answers, missing source, tampering, credential redirects,
and held-out splits. Metrics keep all requested answers in their denominators.
Response validation permits bounded two-decimal rounding while recording the
strict discrepancy; a Choice selecting a lower-probability option stays invalid.

Full run artifacts contain source and coordinator-only labels. Keep them outside
Git, under local access controls appropriate for that source. The remote draft PR
preserves builders, banks, interpreters, tests, protocols, curated results and
samples. It is not a backup of every ignored historical raw capture. New fixture
builds reconstruct the tested mechanisms with new provenance, not identical
historical commit hashes or provider answers.
