# TypeSafe guide validation pass 2: execution and failure contracts

Reviewed 2026-09-17. Read-only independent review of the complete guide's operational contracts, especially the Python example, test suite, replay, source freshness, credential lifetime, commands, and portability. This reviewer did not author the Python example, tests, architecture chapter, or example runbook; earlier authorship of chapters 01 and 05 is disclosed. Pass 1's evidence/completeness review was read for coordination rather than repeated as a numerical audit.

**Final verdict: PASS after correction and independent recheck. Four concrete robustness/portability defects were found, reproduced, corrected by the example author, and rechecked. No blocking concern remains for the documented illustrative-client scope.** The defects are in this new illustrative adapter, not evidence of TypeSafe provider limitations or historical trial failures. No credential lookup, inference, source execution, production mutation, or sealed-artifact edit occurred. The current official API documentation was read over HTTPS; all adapter transport tests were mocks.

## Confirmed findings and exact guidance (all resolved)

### P2-1 — Unbounded integers escape validation/cost calculation

Initial locations: `examples/rank_evidence.py:132–155`, `290–295`, and the stopped-output cost calculation near line 344.

In a temporary fixture copy, replace `receipts[0].response.answers.C001.noul` with the JSON integer `10**400`. The CLI exits 1 with `OverflowError: int too large to convert to float`, no JSON stdout, and a traceback. `math.isfinite(value)` attempts float conversion before the `[0,1]` comparison can reject this invalid probability. The integer is only 401 decimal digits and remains comfortably within the response cap.

Replacing `receipts[0].response.usage.input_tokens` with the same integer also exits 1 without JSON: `known_usage` accepts it, but multiplying by the floating price overflows. Similar counter arithmetic can affect a failed receipt or stopped-output reporting.

**Required correction:** reject out-of-range probabilities before float conversion; define a safe explicit adapter policy for accepted usage magnitudes or use overflow-safe accounting. A numeric counter bound must be documented as a local validation policy, not a provider limit. Invalid remote answers/counters must produce complete-vector fallback, with usable known usage retained and unusable usage marked unknown. Do not merely catch `OverflowError` at top level and lose the normal failure/usage distinction. Add regressions for direct validation, CLI replay, huge failed-receipt usage, and safe near-boundary totals.

### P2-2 — Local JSON container assumptions produce tracebacks

Initial locations: `cards_from` around line 75; `replay_fetch` lines 175–199; `main` lines 310–330.

Independent CLI mutations `manifest = []`, `manifest = null`, `capture = []`, `capture = null`, and `capture.receipts = [null]` each exit 1 with uncaught `AttributeError`, empty stdout, and a traceback. The expected documented result for invalid local data is sanitized `stopped`, exit 2. Remote response arrays/null already become `fallback`; the defect concerns local manifest/capture/receipt schemas.

**Required correction:** validate containers before indexing or `.get` use. Validate the candidate list and candidate objects, capture/provenance/receipts, statuses, and status-specific response shape explicitly. Preserve a fixed reason category; do not print untrusted input or exception strings.

A subsequent recheck also found that JSON exponent `1e309` became infinity and caused a later receipt to fail serialization after earlier usage had been processed. The final correction rejects nonfinite exponent results during parsing and eagerly checks every validated response's JSON/UTF-8 serialization, including invalid surrogate data.

An additional three-batch probe found that status validation was lazy: a malformed second receipt stopped only after the first response had been processed. A first failed receipt followed by later validated receipts was accepted and the later usage silently ignored. Such a capture cannot be produced by the writer's stop-on-first-failure loop. Eager receipt validation and requiring any failed receipt to be terminal fix both ambiguities. These are local capture validation rules, not provider behavior.

### P2-3 — Expected freshness read errors lose already known usage

Initial location: `evaluate.fresh` lines 250–255.

A mocked successful response records 600 input/60 output tokens. If the final `cards_from` recheck then raises an ordinary `OSError`, `main` returns a stopped result with `raw_known_usage: []` and a zero known subtotal. `fresh` attached accumulated counters only to `Stopped`; ordinary expected filesystem/schema errors escaped without that context. This contradicts the runbook's promise that stale/source-check stops retain previous known counters. The output correctly contains no ranking and does not leak the synthetic private error text.

**Required correction:** normalize expected freshness filesystem/schema errors to a fixed stopped category and attach a copy of accumulated usage. Preserve the no-ranking outcome. Validate replay records before starting, or preserve counters on any later local replay stop as well. This is normal error handling, not a demand for durable journaling across process interruption.

### P2-4 — Windows drive paths escape the advertised relative-source root

Initial location: `local_file`, lines 54–69.

The guide describes a portable Python 3.10+ example and source paths relative to the manifest directory. The code rejects POSIX absolute paths and backslashes but accepts `C:/outside/secret.py` and `C:outside.py`. Standard-library path semantics show `PureWindowsPath("D:/snapshot") / PurePosixPath("C:/outside/secret.py")` becomes `C:\outside\secret.py`, outside the source root. A drive-relative spelling also changes the intended root. This was demonstrated with `PureWindowsPath` on Linux; a native Windows run was not available or claimed.

**Required correction:** reject Windows drive-qualified input and alternate-data-stream syntax alongside POSIX absolute/traversal forms, or explicitly narrow platform support. A simple conservative source-path policy can reject colon-containing components; an explicit resolved-root containment check strengthens the ordinary path contract too. Preserve the existing rejection of symlinks. Add portable lexical/path-semantics tests without claiming they establish a hostile-filesystem sandbox.

## Evidence already checked

- The initial 20-unit-test suite passes offline. It did not cover the defects above.
- Copying only `examples/` to a fresh temporary directory, removing `PYTHONPATH` and the API-key environment variable, preserves default replay and all 20 tests. The supplied source fixture is read as bytes, never imported or executed.
- Synthetic default output ranks C001/C002/C003, labels usage synthetic, and calculates the documented known subtotal.
- Saving a replay capture creates mode 0600. A second save to the same path stops with exit 2, leaves its bytes unchanged, and retains the known usage. No overwrite occurs.
- Null/array/Boolean/string *remote response* bodies already cause whole-vector fallback with empty scores and unknown usage; this is distinct from P2-2.
- Existing tests exercise exact answer IDs, model mismatch, duplicate JSON keys, Boolean/nonfinite probabilities, full-vector fallback after later failure, no subsequent request/retry, source/index changes, byte coordinates, path traversal/symlinks, outgoing-field allowlists, response/request caps, and sanitized redirect/HTTP/transport errors.
- CLI default does not read the secret or construct transport. Explicit live mode's mocked test reads the environment once for the process and reuses one client. Real `op`, credentials and provider calls were not used.
- The current [TypeSafe HTTP API](https://docs.typesafe.ai/api) supports the example's fixed endpoint, bearer header, state/model/question map, Noul instructions and true/false criteria, matching answer map, and input/output integer usage shape. The stricter model pin and exact usage-key policy are adapter choices disclosed in the guide. Documentation review is not a live contract test or continued-model-availability proof.

## Explicit limitations that are not new blockers

The guide accurately identifies its synthetic fixture, no live validation of this adapter, non-BM25 illustrative fallback, local request/candidate/batch caps, and absence of selection-quality evidence for the example itself. It does not implement Woods generation acquisition, discovery, packing, author execution, or patch application.

Local snapshots and captures are trusted inputs for integrity checking, not authenticated provider attestations or hostile-filesystem sandboxes. Hashes cannot prevent coordinated edits to both content and manifest. A normal read error still needs the corrected stopped result above; preventing hostile races is an explicitly different scope.

Fixed TLS transport, no redirects/proxy autodetection/retries, bounded body reading, sanitized errors, and owner-only new captures are sensible reference boundaries. The disclosed absence of a hard DNS/header deadline, supervisor, shared cache, encryption, distributed rate limiting, durable attempt journal, and process-interruption recovery is not a claim those systems were implemented. Manual reruns can incur another charge; capture write failure after inference does not roll back usage.

The guide distinguishes runtime Rails extraction from the Woods-only static map, structural index identity from mutable editable bytes, ordinary Index MCP from separately authorized Console live data, and a proposed sidecar from packaged behavior. The proposed workflow preserves deterministic checks, explicit source transmission scope, ordinary review/tests, and recorded fallback.

Root independently owns final archive contents, link/hash/secret scans, and extracted-ZIP validation. This review does not claim those separate checks are complete.

## Independent correction recheck

The author supplied failing-first regression evidence and changed only the illustrative client, tests, and corresponding example/operations documentation. Root added a short lessons section in chapter 08. This reviewer inspected the final code and documentation, then independently ran:

- **21 targeted correction checks:** original malformed manifest/capture/receipt CLI cases; huge Noul/usage integers; accepted and rejected usage-cap boundaries; huge failed-receipt usage; final OSError/ValueError/KeyError/TypeError freshness failures retaining known 600/60 counters; four Windows drive/stream spellings.
- **14 final checks:** positive/negative nonfinite exponents; later receipt infinity and invalid Unicode surrogate; later invalid statuses; rejected nonterminal failure; valid early-terminal failure replay; Python 3.10 grammar parsing; standalone replay; Linux 0600 capture mode; exclusive overwrite rejection; and the copied-directory test suite.
- The complete **28-test suite passed in place and in an isolated standalone copy** with API-key/PYTHONPATH environment entries removed. All real execution was on **Linux, Python 3.14.7**. Python 3.10 was syntax checked only; Windows path semantics were tested lexically on Linux, with no native Windows runtime or ACL validation claimed.

The final implementation checks probability bounds before float conversion; accepts only usage counters in `[0, 1_000_000_000]` per request; rejects malformed local containers and impossible receipt ordering before replay; rejects nonfinite exponents and unserializable later response objects; retains valid usage on expected final freshness failures; and rejects colon/backslash/drive/stream path forms. The local numerical cap is documented as client policy, not a vendor maximum. Out-of-policy counters remain unknown instead of becoming an invented complete zero bill. Windows ACL limitations are now explicit in the example runbook.

The chapter-08 audit lessons match the reproduced cases and now describe the implemented lexical drive/stream rejection without implying an added resolved-root check or a hostile-filesystem sandbox. Existing limitations remain disclosed and do not justify expanding this small reference into a production transport, cache, or evaluator.

**All P2 findings are resolved. No further blocking concern was found.** Root may proceed with its separate final export/archive/hash/link/sensitive-content checks. These corrections do not alter sealed trials, historical scores, or measured TypeSafe effectiveness. No new provider call or credential lookup was made.

### Final reviewed byte identities

SHA-256 records the reviewed bytes; it is not authentication. Later packaging metadata may change independently.

| File | SHA-256 |
| --- | --- |
| `examples/rank_evidence.py` | `d7f82cf7a369243f12edc21027760e602db2b0552fab56a5af098456a2a0325b` |
| `examples/test_rank_evidence.py` | `f2ee7d210695fd5673176a171b08482fdcc2bc157cfb865d60b1723b0e029d9f` |
| `examples/README.md` | `090c1564b75f9accbff0eae03555be790b8e97995457c5b816efa8e438aec186` |
| `02-architecture-and-operations.md` | `0b83fb2ed4c0c02155b51b129b1a2ad778e16a20e83fb2b60796dc67fb704e9c` |
| `08-pitfalls-and-diagnostics.md` | `14261047bb8490e10379bd06d8db639a3fd990b88a3f3edfe354c3b2eee2381c` |
