# Woods support for a practical pre-push reviewer

This iteration completed the Woods-side prerequisites for trying a TypeSafe-assisted
pre-push reviewer: fresh Rails evidence, a checked local extraction receipt, and
portable behavioral fixtures. It makes no new model-quality claim and did not call
TypeSafe. The next useful step is to run the actual reviewer over proposed changes,
with the same evidence supplied to a normal-agent comparator.

The implementation was isolated from the adjacent issue-resolution session at
Woods `c025434fbc003bcec61fafa2808cb6d3d4149fc7`. Public resolved fixes supplied
mechanisms for three small development fixture families; no historical PR-comment
corpus or private application material was used.

## Completed

- [Extraction receipts](../../../script/typesafe/REVIEW_PACKETS.md#record-a-fresh-local-extraction)
  record matching declared application/producer bytes before and after fresh
  extraction, plus the published generation and all payload JSON hashes. Optional
  packet verification rejects stale declared input or index bytes. The existing CLI
  stays unverified; this is a source-checkout Ruby API, not a new packaged MCP tool.
- [Portable fixtures](../../../script/typesafe/fixtures/README.md) provide six
  actual before/after changes: defect/control pairs for cache-key arity, corrupt
  snapshot retention, and authoritative named-route handling. Complete tests,
  neutral packets, separate behavioral oracles, pinned public origins and MIT
  attribution are included. Every supplied smoke test passes; the deeper oracles
  reproduce three regressions and accept three valid controls.
- A frozen public testbed at `d58de911e5fe5e7393be6a497a2b32aa8b7416c2`
  was fully extracted with Ruby 3.3.1/Rails 8.0.5.1 and the corrected callback
  producer. The 393-unit index matches live Rails callback counts of 23, 11 and 9
  for three selected models; model/concern column writes and a dependent association
  are also checked. Its 10-file packet preserves 9 typed unit records and complete
  physical tests/helpers.

The receipt covers 158 application inputs, 287 producer inputs and 431 index JSON
artifacts. Source, producer and index tampering probes all fail on disposable copies.
This remains an unsigned local attestation over declared files: it does not verify
Git identity, the entire runtime environment, installed dependency bytes, database
contents, undeclared additions, or transient change-and-restore.

## Review findings addressed

Two independent review tracks checked implementation/provenance and fixture method.
The fixture audit found an overly broad cache-domain contract. Both baselines and
candidates now enforce identical fixed internal domains, and both neutral tasks
state the boundary. A new behavioral regression demonstrated the issue before the
repair. This does not claim arbitrary-domain uniqueness in production Woods.

Real integration also exposed inefficient allocation in the new receipt reader.
Hashing 287 files took 12.47/13.12 seconds when each read requested a maximum-sized
buffer. After using the open file's actual size and rejecting size drift, the same
inventory took 0.0221/0.0238 seconds. Four regressions failed before that fix and
passed afterward. Both auditors closed with no remaining implementation blockers.

The Woods booted extraction lane passes 38 examples; the frozen testbed passes 36;
the final development suite passes 193. The complete suite passes 8,646 examples
with three optional-tokenizer checks pending; RuboCop passes across 772 files. The
archived kit records the second documentation audit and relocated verification.
No production extraction behavior, public schemas, plugin setup, version, or release
state changed. No GitHub writes were made.

## Handoff

The accompanying `woods-prepush-review-kit-2026-09-17.zip` contains the fixtures,
fresh source/index/packet/receipt, reproduction harness, notices, validation reports,
and an agent prompt. It is a separate supplement to the earlier TypeSafe guide;
that archive and the earlier sealed experiments were left intact.

Use the kit to build an advisory reviewer that reports concrete triggers, source
locations and causal failures. Test narrow Jev judgments with sufficient evidence,
retain misses and abstentions, compare equal evidence, and include the entire
workflow's cost/latency. At the user's stated planning rate of $0.042 per million
input tokens and free output, cheap repeated judgments deserve a fair test. No
inference run in this iteration establishes their effectiveness yet.

Keep known fixture labels away from reviewer calls, and follow development checks
with untouched current changes. The included runtime packet demonstrates Rails
context; it is not itself a labeled change. Do not return to PR-comment mining as
a prerequisite for trying pre-push review.
