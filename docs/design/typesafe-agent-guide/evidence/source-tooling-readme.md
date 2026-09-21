> Portable copy of the source-checkout tooling runbook. The Ruby files and full historical harness are not included in this archive; commands in this appendix require the original Woods working tree containing those uncommitted research files. Use ../examples for the bundled standalone Python reference.

# TypeSafe development evaluation

Implemented slices: an **offline materialized evidence reader**, plus an **offline replay validator and advisory routing experiment**. This is source-checkout-only tooling, excluded from the gem. It does not change extraction, retrieval, MCP or the default suite's network behavior.

```sh
ruby script/typesafe/cli.rb replay path/to/replay.json
bin/rspec spec/development/typesafe/evidence_spec.rb spec/development/typesafe/replay_spec.rb
```

Replay needs neither credentials nor network access. It writes a JSON report to stdout, exits 0 for complete valid responses, 1 for missing/invalid responses, and 2 for invalid input or usage. Exit 0 says the evidence was processed, not that the model passed an adoption criterion.

## Materialized evidence reader

`WoodsDevelopment::TypeSafe::Evidence.read(root:, manifest:)` reads preserved local
files using Ruby 3.0 or later and the standard library. Require
`script/typesafe/evidence.rb` from the source checkout. Supply a String or Pathname
root naming an existing directory and an already parsed, string-keyed Hash:

```json
{
  "schema_version": 1,
  "evidence": [
    {
      "evidence_id": "example-one",
      "path": "materialized/example.rb",
      "sha256": "<64 lowercase hexadecimal characters>"
    }
  ]
}
```

The manifest requires exactly these keys and Integer schema version `1`. It accepts
1–100 entries, each with exactly `evidence_id`, `path`, and `sha256`. IDs must be
unique and contain a character outside Unicode White_Space. Metadata strings may
carry UTF-8 or another ASCII-compatible encoding tag, but their raw bytes must be
valid UTF-8; UTF-16/32 tags are rejected. Caller objects are neither changed nor
frozen.

The result is an Array in manifest order. Each new Hash contains copies of the
three metadata strings (preserving their encoding tags) and `content`, an exact
UTF-8 String. Empty files, Unicode, CRLF, and missing final newlines are preserved
without transcoding or normalization.
Every digest is checked against the raw file bytes. The reader works independently
of the process's default external encoding.

Paths must be relative forward-slash-separated components. Empty paths, leading
slashes, drive-letter prefixes, NUL, backslashes, empty components, `.` and `..` are
rejected. The root and targets are resolved before reading; targets must be regular
files inside the resolved root. In-root symlinks and symlinked root aliases are
allowed; missing targets, directories, special files and escaping symlinks are
rejected. No filename extension is required. This is not a race-proof sandbox:
concurrent hostile filesystem mutation is outside this slice.

`MAX_FILE_BYTES` is 1,048,576 and `MAX_TOTAL_BYTES` is 4,194,304. Exactly-at-limit
files and totals are allowed; repeated paths with distinct IDs count separately.
Reads have a finite byte bound, and non-regular files are rejected before opening
for content. Invalid UTF-8 content is rejected even when its digest matches; binary
evidence is unsupported. Any manifest, filesystem, bound, encoding, or digest
failure raises `WoodsDevelopment::TypeSafe::InvalidEvidence`, without evidence
bytes in the message or a partial return value.

Loading is offline and does not evaluate source, run embedded commands, invoke Git,
fetch history, read labels, access credentials, or write to the checkout. This API
has no CLI integration and does not load a manifest JSON file for the caller.
Existing replay behavior is unchanged.

This manifest binds local bytes to supplied hashes; it is not a complete corpus or
provenance format and makes no source-lineage claim. Git lineage verification,
provenance records, curator attestations, overlays/transformations, whole packet and
context validation, corpus partitions, request preparation, capture/resume, and
inference remain later work. A later corpus authoring workflow must still verify
source lineage before admission, as the evaluation design requires.

## Replay format

A replay object has `schema_version: 1` and a nonempty `cases` array (maximum 150). Each case has exactly:

- `id`, `family`: nonempty local strings; case IDs must be unique.
- `label`: `direct`, `weak`, `absent_in_packet`, or `insufficient_context`.
- `complete`: curator's Boolean attestation about the supplied context.
- `request`: `model`, `state`, `questions`. State contains only string `invariant` and `test_source` fields. Questions contain the original `assessment` Choice alone, or that Choice and all four experimental Noul questions.
- `request_sha256`: SHA-256 of `JSON.generate(request)`, using Ruby's insertion order. This binds replay to its input, not to a signature or authenticated provenance.
- `response`: the recorded API object (`model`, `answers`, `usage`), or `null` for an operational failure.

Unknown fields in local input and provider state are rejected. UTF-8 is validated, and the exact supported Choice rubric and Noul instructions must match the frozen profile before its policy is applied. Response extensions are ignored; required model identity, answer IDs/types, complete Choice distributions, winner consistency, finite probabilities and token counts are checked. Score is deliberately unsupported. Replay expects exact requested/returned model equality; capture experiments must resolve aliases before building this evidence.

Keep author labels, independent reviews and mutation outcomes outside provider requests. A valid request hash does not prove source provenance or correct labels; those require the experiment's separately reviewed corpus manifest and oracle records. The replay format does not yet implement the full provenance, partition, baseline, resampling or capture/resume contract of the design plan.

## Frozen experimental policy: assertion-veto-v1

The existing Choice remains the assessment. Four independent questions ask about missing assertion helpers, exercising the scenario, requiring the entire invariant, and asserting an unrelated result. A Noul measures probability of yes, not assertion strength.

| Condition | Effective route |
| --- | --- |
| Curator marks incomplete context | `needs_context`, retaining raw output |
| Choice is not `direct` | Preserve its verdict |
| Standalone Choice with complete context | Preserve its verdict |
| Batched direct; missing/wrong-result each <=0.2 and scenario/entire-invariant each >=0.8 | `direct` |
| Any other batched direct | `review` |

This is a conservative veto, not an independent classifier. It never promotes a verdict. Thresholds are fixed exploratory policy, not calibrated guarantees. Partial assertions cannot qualify merely because they inspect a relevant property. API questions do not consume one another's answers, and their errors are not assumed statistically independent.

Reports retain raw errors, effective errors, direct retention, review count, family count and intended/completed counts. `raw_exact_matches / intended` includes missing and invalid responses as misses. `direct_retained` counts correct direct cases still available after routing; reducing false direct by escalating everything is not success. Review-only routes are not relabeled as correct four-class predictions.

## First bounded experiment

Four new development families, 16 packets, actual isolated implementation mutations. Each packet receives standalone Choice and all five questions batched. Four preselected packets additionally receive the four Nouls individually and exact repeats of both Choice arms: **56 requests total**, no retries. Primary arms alternate which goes first. Individual-Noul and repeat timings remain exploratory; they are not a randomized load benchmark.

The corpus uses standalone Ruby `raise` assertions adapted from Woods specs, rather than full RSpec execution. Both arms retain the legacy Choice wording referring to RSpec, so this is an explicit format-transfer limitation. Independent labels use the exact outgoing state and are fixed before inference. No assertion that these 4 families or a later 12-family holdout meets the main plan's advancement criteria.

Live capture is still an ignored experiment runner, not a supported CLI command. Resolve the credential once at batch startup (for example, `op run` with a reference-only env file), reuse it in process memory, and never put its value into capture files. Replays do not contact 1Password. Explicit repeat trials must bypass response caches; ordinary re-analysis uses captures.

[Full evaluation design](2026-09-16-typesafe-development-evaluation.md) remains the larger target. Provenance/partition validation, stronger baselines and family-level metrics are still incomplete. Later development trials are recorded below; none satisfied the adoption requirements. No production gate is implemented.

## First pilot outcome

The 56-request development pilot completed on 2026-09-16 with `jev-1.13.0`. Standalone Choice matched 15/16 labels; batched Choice matched 16/16. Neither produced a false direct judgment. The veto escalated all four correct batched-direct cases, so this rule is **not recommended for advancement**. It remains implemented only to reproduce and inspect the experiment. Eight repeat Choice labels were stable; that does not establish correctness or determinism. Batch versus separate calls for the same five questions on four packets used 64.8% fewer input tokens.

Do not revise thresholds on these examples and present the resulting fit as validation. The next independent value experiment is claim support, after its corpus and rubric are prepared; wider assertion evaluation still needs fresh families and stronger baselines. The original full evaluation plan's adoption requirements remain in force.

## Subsequent evaluation status

Claim-support and focused diagnostic trials are recorded in [plan sections 16–18](2026-09-16-typesafe-development-evaluation.md#16-claim-support-development-pilot). They do not establish a general verification or coding advantage.

The original [context-selection pilot](2026-09-16-typesafe-development-evaluation.md#19-prospective-context-selection-pilot-and-operational-stop) stopped when its full-context request returned HTTP 400. Separate marker probes succeeded with a small state and failed with the original full state even for one question. That trial produced no paired coding result or exact provider limit and remains preserved separately.

The [compact retry](2026-09-16-typesafe-development-evaluation.md#20-compact-context-selection-retry-and-offline-reader) succeeded with three API calls and one credential lookup. Ordinary-agent and TypeSafe selections differed by one example; TypeSafe's exact repeat kept the same selection. Two fresh authors implemented the same `Evidence.read` contract within equal time budgets. Both frozen submissions passed all 116 independent behavioral checks, so this development trial showed **no completion advantage** for TypeSafe. A blind review found no blockers in either version; the retained implementation was preferred for clearer failure diagnostics, not as evidence of selector superiority.

At the published $0.042 per million input tokens with free output, the primary selection cost an estimated **$0.00028035** (about **$0.28 per 1,000 similar selections**); the complete three-call retry cost $0.0008274. These are API estimates, not invoices. Matching acceptable coding quality at a lower total cost is a separate potential benefit: comparator usage and downstream costs were not measured, so savings remain unquantified. [Plan section 21](2026-09-16-typesafe-development-evaluation.md#21-cost-efficiency-as-a-separate-benefit) describes a fresh cost-focused comparison rather than requiring TypeSafe to write better code to be useful.

The offline reader above is now implemented. Full source lineage and the wider evaluation pipeline remain deferred. Keep TypeSafe experimental: this reused task, two authors, and agent-based review do not establish general coding value or satisfy held-out adoption requirements. No production dependency, automatic acceptance, or CI inference was added.
