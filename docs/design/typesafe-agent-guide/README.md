# TypeSafe for development agents: a practical research-backed guide

Prepared **2026-09-17**. This handbook explains how to use TypeSafe as a small typed-decision component in a development workflow, both with and without Woods. It includes implementation contracts, runnable examples, failed approaches, experimental results, cost calculations, and a path to evaluating a new project.

Updated **2026-09-21** with [booted Rails review and fix-verification lessons](10-booted-review-lessons.md).
The original trials remain historical evidence; chapter 10 records the newer
main/testbed revisions and both positive and negative outcomes.

**Recommended starting point:** optional, inexpensive ranking of bounded source evidence for a separate coding agent. Keep deterministic discovery, exact source identity, code generation, review, and execution in their own components. Our trials show useful feasibility; they do not establish a production-default policy, general bug-finding ability, or an automatic correctness gate.

TypeSafe did not write the patches in our studies. It selected evidence. A separate coding model wrote code, which was checked with independent tests. At the recorded estimate of **$0.042 per million input tokens and free output**, a selector can be valuable through inexpensive substitution or better evidence even when it does not improve every completion rate or reduce context.

## Read this in the order that fits your task

| Your task | Read |
| --- | --- |
| Understand what TypeSafe can do | [1. Concepts and patterns](01-concepts-and-patterns.md) |
| Build a safe, reusable integration seam | [2. Architecture and operations](02-architecture-and-operations.md) |
| Select useful code/source context | [3. Evidence selection](03-evidence-selection.md) |
| Evaluate code-writing outcomes honestly | [4. Authoring and evaluation](04-code-authoring-and-evaluation.md) |
| Use Woods or the Woods testbed | [5. Woods integration](05-woods-integration.md) |
| Inspect every meaningful trial result | [6. Trial ledger](06-trial-ledger.md), then [full evidence](evidence/README.md) |
| Decide whether the price and quality justify adoption | [7. Cost and adoption](07-cost-and-adoption.md) |
| Diagnose a failure or avoid a known pitfall | [8. Pitfalls and diagnostics](08-pitfalls-and-diagnostics.md) |
| Hand the implementation to another agent | [9. Agent playbook](09-agent-playbook.md) |
| Build an application review shortlist or check fixes | [10. Booted review lessons](10-booted-review-lessons.md) |
| Run an offline reference implementation | [Examples](examples/README.md) |
| Check this archive or transfer it | [Validation](VALIDATION.md), [transfer instructions](TRANSFER.md) |

A useful first reading path is **1 → 3 → 5 if applicable → 6 → 7 → 9**. An implementing agent should also read chapter 2 and run the examples. A reviewer should read chapters 4 and 8 before evaluating a proposal.

## The strongest results and their limits

- **Retrieval:** on 28 Canopy queries, TypeSafe reranking raised mean relevant-unit recall from 57.98% to 77.02% at the 1,200 budget. Primary inference cost about $0.0123. It still displaced some previously returned evidence. A .5 relevance filter lost baseline-labeled IDs on 12 queries and was not suitable for general evidence-preserving compression.
- **Curated coding repairs:** TypeSafe-ranked method evidence led to 4/4 accepted repairs, versus 2/4 for lexical-ranked methods at 1,000 reference source tokens. This used a curated file universe and one author draw per condition.
- **Description-only discovery and new features:** the later study had 28 attempts over four tasks. TypeSafe at 1,000 tokens passed 4/4 tasks on each of two draws; BM25 passed 3/4 on each. Both passed 4/4 at 3,000 tokens, and both new features passed under every condition. Primary selection cost about $0.00704 across the four tasks.
- **Verification:** promising constructed assertion/claim results did not translate into a validated broad PR gate. A conservative assertion veto discarded all four correct direct decisions. Instruction asymmetry, missing evidence, ambiguous labels, confidence, and near-tie choices materially affected interpretation.
- **Real findings:** deterministic source/execution audits found final-context token-accounting, NUL search, and Boolean-field search bugs in Woods, plus two regression-coverage gaps in the testbed. They were filed separately; they were not attributed to autonomous TypeSafe discovery.

All figures are development evidence with small, correlated, sometimes exposed task sets. Passing frozen tests is not exhaustive compatibility. Inference estimates exclude unmetered research effort and are not verified invoices. See the ledger for denominators, negative results, actual author telemetry, and posthoc findings.

## Run the portable examples

From this guide's directory, with Python 3.10 or later:

```bash
python3 examples/rank_evidence.py
python3 -m unittest discover -s examples -p 'test_*.py' -v
```

The default is offline synthetic replay. It needs no API key, network call, Woods installation, Rails application, or 1Password access. The synthetic result demonstrates protocol behavior, not model quality. Live mode is explicit and has additional requirements and limitations described in the examples runbook. Do not put a real key into the example files.

## What this archive is—and what an agent must not assume

This is a portable knowledge handoff plus a small illustrative reference implementation. It includes the research reports needed to understand the conclusions. It does not include the full private evaluation corpora, ignored raw captures, temporary source trees, generated Woods indexes, or personal agent configuration needed to repeat every historical run exactly.

Chapter 10 additionally includes one actual synthetic application request/response
as an evidence-construction example. The complete new raw captures and reviewer
transcripts remain outside this portable guide; its report includes their metrics
and limitations.

At handoff, Woods' source checkout contains an offline materialized evidence reader and assertion replay tooling. The live experimental runners, general corpus/holdout architecture, broad routing ideas, and a production selector service are different stages of completion. Every chapter distinguishes implemented behavior, measured experiments, and proposed adaptations. No TypeSafe dependency, default inference, public MCP change, or automatic patch acceptance was added to the packaged gem.

The audited Woods source is `55a74ea4f3a7c3e798493a92663003aab85a2301`; the companion testbed source is `f5f603f92a16f385d4fc825d72c7232a75014da4`. Check the installed version and live docs before adapting this to a newer release. Never substitute the Woods-only static self-map for booted Rails extraction or infer executable tools from schema inventory alone.
