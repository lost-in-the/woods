# Four follow-up TypeSafe development tests

This protocol is prospective. The four questions share FOUR fresh task blocks (two Woods, two Canopy) and 28 intended coding attempts. They are not four independent datasets. Preserve all prior experiments. Production code remains unchanged; run repairs/features only in isolated snapshots.

## Questions and fixed comparison cells

1. Discovery: can a fixed description-only Woods search and deterministic shortlist expose useful code without curator-provided file localization? Count indexed target coverage, MCP discovery coverage, clipped-source availability, top-80 availability, and delivered evidence separately. Curator target/reference paths are private diagnostic labels, never discovery input. Missing candidates cannot be rescued by a reranker.
2. Evidence sufficiency: compare BM25 and TypeSafe at 1,000 and 3,000 reference source tokens, plus a BM25 8,000-token larger-source reference. It is not called full source unless exact coverage establishes that. Reuse the same primary TypeSafe score vector across budgets. Keep the prior ordered-prefix packer unchanged, including partial final candidates, and record completeness.
3. Feature implementation: separately report the two genuinely additive features, alongside the two controlled repairs. Private acceptances test required behavior and compatibility. A separate author writes code; TypeSafe only selects evidence.
4. Stability and failure handling: rerun the exact TypeSafe requests once, solely to quantify score/order/context stability. Repeat BOTH 1,000-token author policies once using their ORIGINAL frozen contexts, isolating author variability from selector changes. Offline fault injection must produce byte-identical BM25 fallback on any incomplete/invalid task ranking. A stale source fingerprint stops the experiment; it is not an authoring fallback.

Exactly seven cells per task: bm25_1000_r1, typesafe_1000_r1, bm25_3000_r1, typesafe_3000_r1, bm25_8000_r1, bm25_1000_r2, typesafe_1000_r2. Fixed shuffled execution seed 20260918. Every cell stays in the denominator; identical contexts also run. The second author draw is a stability probe, not an independent task. There are no postfailure retries or follow-ups.

## Tasks and oracle controls

- Woods repair: restore literal metadata substring matching for SQL punctuation, preserving field validation, empty-field behavior, adapter behavior and persisted data.
- Woods feature: add exclude_tags: to evaluation query filtering while preserving existing filters, order, identity, exact tag equality and immutability.
- Canopy repair: restore publication-scoped newsletter recipients without disturbing organization isolation, subscription status, uniqueness or send eligibility.
- Canopy feature: add live refundable_cents to payments, with persisted-refund aggregation, captured-state restriction, zero clamp, STI, stale loaded-association behavior, unsaved-record exclusion and no writes.

These are fresh evaluation tasks, not found production bugs. Feature implementations were not removed from existing code. Hidden reference implementations pass independent acceptances plus matching existing specs. Initial repair snapshots fail intended acceptance; initial feature snapshots fail for absent behavior while existing behavior passes. Adversarial incorrect variants validate selected acceptance boundaries. No task/reference/test bytes enter selector or author state. Ordinary source comments remain visible and may make implementation easier.

## Source state and discovery

Use same-HEAD isolated source snapshots. Woods has a newly generated self-map per incomplete snapshot. Canopy has ordinary booted Rails runtime extraction per incomplete snapshot, separately validated. The static map is not Rails reflection. Runtime units identify application source; Prism segments exact source bytes without claiming runtime semantics.

Only generic source roots are eligible: lib/**/*.rb for Woods and app/**/*.rb for Canopy. Exclude tests, docs, task metadata, hidden references, prior experiments and ignored artifacts. Woods search types: ruby_file. Canopy types: model, controller, service, job, mailer, concern, poro. Other runtime types are outside this prospectively fixed discovery policy.

Public input is task description only. Tokenize using fixed camel-case splitting, lowercase ASCII alphanumeric words, fixed stopwords from common.py, and length >=3. Search all unique tokens in lexical order as escaped Ruby-regex alternatives, over identifier and source_code, limit1000. Use the packaged MCP executable with JSON presentation configured; query/ranking semantics are unchanged. Keep the packaged default500 source-scan cap, clearing any external override. Record partial status, notes, raw matches, timing, and result_count>=1000 as possible result-cap truncation. Neither flag triggers target rescue or revised queries.

Resolve matches to source files through the published unit payloads. Merge duplicate paths and sort them. Retain only actual regular Ruby files beneath the fixed source root. Parse source using the recorded installed Prism/Ruby versions. Top-level method ranges include mechanically adjacent comments/blank lines; nested definitions stay within the outer method. Preserve meaningful nonmethod source in support cards. Omit only whitespace and closing end lines. Preserve public/private/protected directives as actual source in support cards; do not infer runtime visibility from static segmentation. Raw spans retain original file hashes and byte coordinates.

If a card exceeds16KiB, keep its maximal valid UTF-8 prefix, record original hash/range and complete_original=false. Both ranking policies and packing see only those clipped bytes. No card is dropped based on its target relevance. Deduplicate file/byte spans. Any malformed/unalignable source or stale fingerprint stops preparation; do not manufacture source or silently restore correct code.

BM25 first-stage ranking uses the token stream identifier + file_path + namespace + clipped source, k1=1.2,b=.75, log(1+(N-df+.5)/(df+.5)), unique query terms, and identifier/file/start-byte/end-byte ties. Retain at most80 candidates. This is a stronger, NEW deterministic baseline, not the prior pilot's unique-overlap score. Do not pool their success rates. Provider order is identifier/file/range, withholding BM25 scores and ranks. No task-specific boosts or private-path query additions.

## TypeSafe operations

Use jev-1.13.0 and the same pointwise Noul usefulness judgment for every candidate/task. The request carries description and allowlisted source identity, kind, path, namespace, range, clipping status and source. No targets, reference patches, tests, ranks or outcome labels. Scores are relevance judgments, not calibrated coding-success probabilities.

Greedily batch complete card packets in canonical order into requests <=24KiB. Stop preparation if one encoded candidate cannot fit. The repeated selector uses byte-identical request files; it is never substituted into primary or repeated author contexts. Record primary and repeat usage separately. Schedule all primary packets first, then one repeat of each. No retry or adaptive extra request. Maximum128 scheduled calls; if construction exceeds this, stop and review before any call. Retrieve 1Password once in the process, retain key only in memory, and never put it in output or files.

Use inherited exact-ID/model/probability/usage validation, duplicate-key rejection, 45-second call deadline, 5-second connect,20-second read/write,1MiB response cap and sanitized errors. Stop on the first failed call or after known input use exceeds3M tokens. This usage bound is not an invoice guarantee. Discard the complete task score vector if any of its required chunks are absent/invalid, and use its complete BM25 ranking. Unattempted repeat requests remain missing stability observations. Failed and unknown-cost requests remain reported.

## Packing and authors

All policies use the prior ordered-prefix packer: append complete rendered candidates until one does not fit; append a deterministic feasible source prefix with a truncation marker, then stop. No skipping, oracle repair or helper hydration. Budgets1000/3000/8000 use cl100k_base via the pinned local tiktoken package; headers, fences, markers and introduction count. These are source-reference budgets, not actual total author input or billing. Record exact delivered byte spans, clipping and completeness.

Freeze all28 contexts/prompts and schedules before authors. The public prompt includes only description, generic allowed source root and selected evidence, never private editable paths. An author may modify ANY delivered existing source file under that root. No new files or test/config/script changes. Exact unique old text must be visible at the corresponding original byte offset in a source span for the SAME file. Validate every ledger against untouched snapshot bytes, reject overlapping edits and apply replacements simultaneously by descending original offsets. New text may be empty. Maximum8 replacements. An empty list is an abstention and failed primary endpoint.

Retain the user's configured CLI author model/effort, record config hash/version and verify before each launch. Use one fresh opaque temporary cwd and process per cell, restricted read-only/tool-disabled configuration, no conversation reuse, no task-specific project AGENTS, stripped credential environment and existing saved login. Shared system instructions may remain; this does not prove host files physically inaccessible. Any tool event, malformed required usage, invalid JSON or process failure is a protocol failure. Preserve raw events, counters, parsed output and failure reasons; absent optional counters are unknown.180-second author deadline. No repair, retry, testing feedback or author access to hidden tests.

## Evaluation and measures

Review exact submitted patches for execution hazards/evaluator bypass only; ordinary incorrect fixes face tests. Rejected submissions remain failures. Copy complete frozen trees into unique temporary checkouts. Woods runs Ruby syntax, hidden acceptance and matching existing specs. Canopy uses the fixed audited Docker adapter, unique /tmp app and database per attempt, separate hidden and existing Rails specs, and no live app data. Bind all transitive helper files and exact tests. No empty/aborted test run may pass; require declared success markers and positive expected example counts.

Primary acceptance requires valid patch, syntax, independent behavior and existing specs all to pass. Report all28 cells and per-task paired comparisons, distinguishing author format/operation, application, syntax, behavior and abstention. Feature and repair results are separate views of the same task blocks. Coverage diagnostics never override behavior-based acceptance. Any posthoc audit supplements the frozen score rather than rewriting it.

Report actual author input/cached/output/reasoning counters and elapsed time including unsuccessful attempts. Record selection and repeated-selection request usage, latency and errors. Estimate TypeSafe charges at $0.042/M input, free output. Keep providers' tokens separate, exclude unmetered curator/reviewer effort from inference-cost claims, and disclose CLI billing/subscription unknown. Compare quality and latency; tiny selector cost need not be justified only by compression. Different cache hit rates and one/two author draws prevent causal billing claims.

## Review, freeze and stopping

Independent plan review precedes measured calls. Audit final discovery, source/requests, packer, oracles, helper/harness and controls; bind prospective bytes. Then run bounded selection, independently audit selected contexts and freeze authors. No outcomes tune queries, clipping, budgets, tests or ranking. Review all patches before execution, independently recount outcomes, and preserve prior completed studies. File only confirmed newly discovered production bugs/coverage findings after duplicate checks, not seeded mutants or experimental author errors. New evidence remains ignored under tmp/typesafe-next-four; durable plan/results live in docs/design/plans.

Before any provider/author call, independent review found that v1 omitted visibility directives without restoring them in metadata. Discovery v1 and its requests/contexts are archived unchanged. Representation v2 preserves these directives as support source; query, BM25, clipping, shortlist, packing, budget and prompt rules are unchanged. Regenerate once mechanically and bind v2. This is a generic source-semantics correction, not outcome-based tuning.
