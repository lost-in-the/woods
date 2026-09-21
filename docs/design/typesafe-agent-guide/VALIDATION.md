# Guide validation record

## September 21 addendum validation

Chapter 10, its full report and its single synthetic request/response were added
after the original reviews below. They received two coordinator validation passes,
not a claim of new independent reviewer approval:

1. Recomputed the 101-call ledger from raw responses, verified frozen request and
   response hashes, and checked all eight behavioral oracles, clean candidate
   revisions, generation-2 deep freshness results and selected source hashes.
   Reviewed the four agent command traces and their enforced four-packet budgets.
2. Recounted usage including invalid responses, checked question polarity and
   diagnostic-versus-discovery wording, linked sample bytes to their original
   hashes, checked new links/JSON and scanned the added exports for personal paths,
   credential references and private-key markers. All 28 existing offline example
   tests passed. The archive checksum, extraction and example tests were rechecked
   for the September 21 archive.

This update records four failed strict Choice validations separately from scalar
judgment quality and preserves both downstream comparisons, including the routed
arm's slower time. The original reviews below apply to the September 17 edition.

## Original September 17 edition

Completed **2026-09-17**, after the four-test experiment was finished and sealed. Two explicit guide validation passes were performed; both concluded with **no blocking concerns within the documented scope**. The full reviews are included so a receiving agent can inspect findings, corrections, exact evidence, and reviewer limitations.

## Pass 1: evidence, completeness, and interpretation

The [first review](evidence/guide-validation-pass1.md) read all chapters and exported evidence, compared them with the original reports and current raw aggregates, and checked the TypeSafe documentation research and canonical Woods contracts.

It verified coverage of all **27 requested documentation/demo topics**, including the smart-home direction; all meaningful positive and negative trial outcomes; implemented versus experimental versus proposed capabilities; Woods/testbed boundaries; selection versus authoring; independent task denominators; and the limits of confidence, coverage, and behavioral acceptance.

The reviewer independently recounted the current 28 author attempts, 26 accepted patches, two abstentions, provider request/token totals, author cache/reasoning subsets, repeated-test counts, and stability results. Cost formulas were recomputed using $0.042 per million input tokens and free output. All nine original research-export hash pairs matched at this pass; the two later review exports have their own entries in the final source manifest.

One link that left the portable directory was corrected to its bundled evidence copy. An editorial note now explains two shorthand phrases in the frozen prospective plan: private task/oracle metadata was excluded, while public task descriptions were supplied; BM25 was a different baseline whose relative strength against the earlier lexical baseline was not directly measured. Original reports and frozen outcomes were preserved.

This reviewer previously authored chapters 04 and 08. That contribution is disclosed in the full report; the review is not represented as a wholly independent revalidation of its own prose. The coordinator also checked sources, links, arithmetic, and interpretation.

## Pass 2: executable contracts, failure handling, and portability

The [second reviewer](evidence/guide-validation-pass2.md) had not authored the Python client, its tests, architecture chapter, or example runbook. It inspected code and documentation, checked the current official API shape, ran the examples in isolation, and probed malformed inputs and failures independently. Its earlier authorship of chapters 01 and 05 is disclosed.

Four findings were reproduced before correction:

1. Huge integers could crash probability validation or cost arithmetic. Bounds now precede float conversion, usage counters have an explicit local ceiling, and nonfinite exponent results are rejected.
2. Invalid manifest/capture/receipt containers could escape as tracebacks. Replay now checks containers, serializability, statuses, and terminal-failure ordering before consumption.
3. A later source-read error could hide previously known usage. Expected freshness errors now stop ranking while preserving validated counters.
4. POSIX-only path validation accepted Windows drive-qualified paths. The portable path policy now rejects drive/stream syntax, with native-platform limitations stated explicitly.

A correction recheck caught an additional exponent-overflow case within the replay finding; that was also fixed before acceptance. The reviewer inspected the resulting code and ran **21 targeted correction checks plus 14 final checks**. All **28 offline unit tests** passed in place and after copying the example to a fresh directory. Capture creation and overwrite protection were checked, along with known/unknown usage, malformed later receipts, source errors, and deterministic fallback. The lessons are incorporated into chapter 08.

Execution used **Linux and Python 3.14.7**. Python 3.10 grammar compatibility was checked; Python 3.10 runtime and native Windows execution were not tested. Windows drive/stream cases used lexical/path-semantics checks on Linux. Mode `0600` was verified on Linux; Windows ACL behavior is left to the host. No credential lookup or live inference was performed for the guide reference.

## Portable archive checks

The coordinator checked internal Markdown links and local anchors, fenced blocks, JSON parsing, Python syntax, and ten distinct pinned Woods source-document paths. All eleven original/export report-and-review hash pairs in `evidence/source-manifest.json` match. Aggregate metrics match the sealed experiment. All **10,358 sealed experiment artifacts** remain unchanged.

The curated files were scanned for personal absolute paths, the investigation's private item identifiers, non-placeholder secret references, and private-key markers. No such material was found. Raw captures, personal configuration, private acceptance corpora, generated indexes, live captures, bytecode caches, and symlinks are excluded. Only a placeholder `op://VAULT/ITEM/password` reference is supplied.

Archive validation verifies one relative top-level directory, ZIP integrity, every extracted file against its source bytes, and `sha256sum --check SHA256SUMS`. The extracted offline example and complete 28-test suite are run outside the repository with no API-key environment entry. Transfer syntax was checked against the installed Tailscale CLI; no file was sent to another machine.

`SHA256SUMS` covers every bundled file except itself. It detects accidental changes; it does not authenticate an archive if an adversary replaces both content and hashes. Full review-file identities are also recorded in the source manifest.

## What these passes do not establish

This is a knowledge handoff and illustrative adapter, not a production service or complete historical replay dataset. The Python fixture is synthetic and has no measured selection quality. Its live endpoint/model compatibility still needs a small explicit live check before deployment; reviewing API documentation and mocking HTTP do not substitute for that check.

The archive excludes the private/raw artifacts needed to reproduce every historical run. Small, correlated development studies do not establish population-level superiority, safe automatic approval, general bug discovery, or performance guarantees. Hard DNS/header deadlines, durable attempt journaling, authentication of captures, shared-cache authorization, and hostile-filesystem containment are outside the example's claims.

The full gem suite, RuboCop, and Rails version matrix were not rerun for this documentation/example handoff because packaged Woods behavior did not change. Relevant historical execution results remain in the trial reports; the standalone Python example received its own executable checks. No release, production deployment, or default CI integration was performed.
