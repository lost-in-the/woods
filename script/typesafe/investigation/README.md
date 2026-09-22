# Bounded evidence investigation pilot

This is a separate source-checkout experiment alongside the retained six-question
and full-bank implementations. It compares a deterministic supporting-file rule
with Jev choosing up to two source inspections, using the same initial scan and
focused follow-up questions. It is not a packaged gem feature or a production
application reviewer. Read the [prospective protocol](protocol.md).

## Reproduce the fixtures

The builder needs the public Woods testbed Rails 8 large app, a compatible cached
Docker image and populated read-only bundle volume. It builds disposable copies
and pins Woods runtime files. Existing original apps/captures are preserved.
Use explicit paths and a new output directory; see `fixtures.py --help` for image,
volume and Docker-command overrides. The selected cases exercise decimal
rounding, fixed-field JSON input shape, nested transactions and calendar dates.
Private executable outcomes live outside provider state.

From the repository root, with an intact disposable base produced by the retained
[`build_original_pairs.py`](../rails_bank/build_original_pairs.py):

```bash
python3 script/typesafe/investigation/fixtures.py \
  --woods-root "$PWD" \
  --woods-revision 9f55ee840e22b160a148c48da3dcef1210d07ed7 \
  --template /path/to/disposable/rails-fixture-base \
  --output tmp/investigation-fixtures-new --prepare --run --jobs 2
```

The default cached image is `woods-testbed-rails-8.0-large:latest`, with bundle
volume `woods-testbed-bundle-rails-8-large`. Use `--docker-command 'sudo -n docker'`
only when required by the local Docker setup. No image pull occurs, and the bundle
and archived Woods runtime are mounted read-only. Each candidate gets its own
application/database copy. The original base is preserved. This builder was run
on Python 3.14.7; its Python 3.9+ compatibility has not had a version-matrix run.

## Prepare and run

After the fixture builder reports all eight cases verified:

```bash
investigation_output="$(mktemp -d)"
PYTHONDONTWRITEBYTECODE=1 python3 script/typesafe/investigation/runner.py prepare \
  --fixtures /path/to/verified/fixtures --root "$investigation_output"
```

Inspect the frozen `protocol.md`, `preflight.json`, `initial/`, `cards/`,
`scan-requests/` and `ledgers/` before capture. Preparation validates captured
freshness, revision and source hashes, copies private oracle/evidence receipts,
and checks every allowed zero/one/two-card combination against byte budgets.
It does not recheck a later live application checkout. Unopened bodies, labels,
fixture families and necessary-card lists do not enter the initial state/menu.
Fixture-specific time-zone premises remain behind their configuration card.

Provide the key through the environment, once for the capture process. For
example, use an existing reference-only env file with `op run`:

```bash
op run --env-file /path/to/reference-only-typesafe.env -- \
  python3 script/typesafe/investigation/runner.py capture \
  --root "$investigation_output"
```

The env file should contain `TYPESAFE_API_KEY=op://VAULT/ITEM/password`, not a key
value. The capture creates durable request/response receipts, refuses overwrite,
blocks redirects and automatic proxies, and makes no automatic retries. It uses
socket timeouts rather than a hard overall network deadline. Import and prepare
never contact the provider. Live capture sends selected source and incurs usage.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 script/typesafe/investigation/runner.py summarize \
  --root "$investigation_output"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s script/typesafe/investigation -p 'test_*.py'
```

## Read the result correctly

Each candidate/repeat shares one exact 204-question scan between arms. Initial
hints contain only valid defect Nouls with declared evidence and applicable
Tests/Views premises. Scores and conventions stay out of hints; all raw answers
remain preserved. A declared supplied requirement is not a proof of semantic
sufficiency. No maximum answer is treated as a whole-change probability.

The static rule uses only changed source and menu names. The adaptive rule may
read a card, stop, or report missing context. The second selection sees the first
card's body. Code executes only an offered read; invalid routing stays visible
without a hidden retry/fallback. It stops further reads, then runs the focused
questions on the source already observed; it does not automatically mark every
focused answer unassessed. Both arms receive the same four judgment
definitions: concrete contract violation, missing context, mechanism and source
location. A location may only refer to already observed source or `none`.

`raw_high_lead` is a typed-model lead, not a confirmed finding. Evaluate necessary
card coverage separately, with the private manifest, and independently compare
the actual claimed mechanism to source and executable results. Controls establish
only their specified contracts. A high answer on a control requires investigation.

Actual usage counts shared scans once. A hypothetical standalone workflow would
pay for its own initial scan if it includes that stage. Static selection and focus
do not consume its hints, so a static-only workflow can omit it entirely. Report
the chosen allocation explicitly instead of adding
both hypothetical totals and calling it actual spending. Missing usage, unfinished
jobs and invalid answers remain visible. Two repeats on eight curated candidates
do not establish whole-app discovery, calibrated accuracy or downstream reviewer
token savings. Subsequent experiments must preserve this version and avoid calling
these exposed cases a new holdout.

The [first results](../../../docs/design/plans/2026-09-21-typesafe-investigation-results.md)
record the actual capture with the runner preserved at commit `6c06c6ca`.
Post-capture summary format `2026-09-21.2` preserves interrupted attempts with
unknown latency instead of failing. Time sums cover recorded values only; inspect
`unknown_latency_attempts` alongside them. Future preparations also snapshot the
runner and retained dependencies before hashing the inputs. These bookkeeping
changes did not modify or rerun the original frozen capture.

Only code and deliberately curated reports belong in Git. Local fixture databases,
indexes, raw transcripts, private labels and credentials are not automatically
published by these scripts. Inspect `coordinator-*` files as experiment evidence;
never send them wholesale to a model.
