# Quick documentation audit with TypeSafe

This source-checkout experiment samples coherent Markdown sections and asks Jev
separate readability, relevance and source-backed accuracy questions. It returns
typed signals and exact candidate block locations; a reasoning reviewer checks
the leads. It does not edit documents or certify a release. The retained Rails
bank runner is reused for provider transport and answer validation, unchanged.

Read [protocol.md](protocol.md), [rubric.json](rubric.json) and the explicit
[audit-plan.json](audit-plan.json). The first plan audits a pinned Woods main
revision, with two sections per page across 17 pages. Complete selected sections
and source/spec spans go to the provider; omitted sections are listed, not judged.

```bash
audit_output="$(mktemp -d)"
PYTHONDONTWRITEBYTECODE=1 python3 script/typesafe/docs_audit/runner.py prepare \
  --source /path/to/pinned/woods --root "$audit_output"
```

Inspect `preflight.json`, `coverage.json`, `source-ledger.json`, the frozen
protocol and requests. To adapt, create a new explicit plan with the checkout
revision, each page's audience/purpose, exact heading names and selected source
line spans. Preparation rejects dirty tracked files, missing/ambiguous headings,
unsafe paths, unclosed fences and oversized packets. It preserves code fences
and exact UTF-8 line spans, including CRLF. This is a small ATX-heading parser,
not a complete CommonMark parser. Parent introductions exclude child sections;
ancestor titles and all omitted-section identities remain explicit.

Live inference is a separate explicit step with source transmission and provider
usage. Use `TYPESAFE_API_KEY` already in the environment or one reference command:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 script/typesafe/docs_audit/runner.py capture \
  --source /path/to/pinned/woods --root "$audit_output" \
  --credential-command op read 'op://VAULT/ITEM/password'
PYTHONDONTWRITEBYTECODE=1 python3 script/typesafe/docs_audit/runner.py summarize \
  --root "$audit_output"
```

The command is an argument array, never a shell. The key is not printed or
persisted; existing captures refuse overwrite. There are no automatic retries.
The shared transport has socket timeouts and a response cap, not a hard total
deadline. Frozen snapshots permit offline summary; replay never calls the API.
Source and runner changes between preparation and capture stop the batch.

Keep all raw judgments and failed-request accounting. `supported` is a model
signal about supplied spans, never a verified verdict. `missing_evidence` remains
unassessed. Scores are subjective ordered dimensions, not error probabilities;
confidence measures distribution concentration. Every selected accuracy block
needs an independent source/spec check. Record confirmed errors separately from
wording preferences and evidence gaps, with precise source lines and any repro.
Coverage denominators refer only to selected pages and samples, not the entire
documentation tree. These source-bound receipts are not provider attestations.

Offline checks:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s script/typesafe/docs_audit -p 'test_*.py'
```

See the [reusable audit runbook](../../../docs/development/DOCS_QUICK_AUDIT.md)
and [first results](../../../docs/design/plans/2026-09-21-typesafe-release-docs-audit.md).
