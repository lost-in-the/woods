# 08. Method and limits

## What ran

Ten parallel research passes over HEAD `79c156d`, then independent re-verification of every High and Medium by the synthesizing session.

- **Phase 1, ledger reconciliation (2 passes).** Every prior-audit ledger row: closing commit found via `git log c31683c..HEAD` and `git log -S`, fix diff read, HEAD code read, regression spec read and judged, then the fix's neighbouring shapes attacked. ~130 executed probe shapes against the real validator/redactor/naming/dump classes.
- **Phase 2, fresh audit (8 slices).** Extraction core; extractors A (model/controller/concern/job/mailer/service + naming helpers); extractors B + AST/flow/graph; Index MCP + retrieval; Console MCP; storage + embedding; daemon + infra; exporters + evaluation. Every lib file in each slice read in full, every matching spec read in full. Slices did not overlap files.
- **Phase 3, synthesis.** Every executed High/Medium probe re-run from scratch by the synthesizing session. Every traced Medium's citations re-read at HEAD. One probe found mis-written and corrected (EXTB-7: the committed order-swap did not swap; the corrected probe reproduces the finding). Deduplication against the backlog, the prior audit, and across agents (R1-2=EXTA-5, R1-4=R2-1, EXP-4 folded into INF-4, EXP-7/R2-3 folded into the encoding family).

Executed infrastructure:

- Full default suite at HEAD under the POSIX locale: 7254 examples, 4 failures (1 real finding, 3 root-environment artifacts), 2 pending.
- ~2,900 further spec examples across slice baselines and probe spec runs.
- The `:http_server` opt-in lane (green).
- ~45 probe scripts, preserved in the session scratchpad under `core/`, `exta/`, `extb/`, `con-slice/`, `mcp-slice/`, `sto-probes/`, `inf-slice/`, `exporters/`, `ledger-recon/`.
- The static self-map (`woods:self_map`) built and used for blast-radius lookups.

## What was only read

- The M11 directory-fsync effect under real power loss (unprovable in-process; the fsync calls are spec-pinned).
- The mcp gem 1.2.x rows of the supported range (only 1.4.0 installed here).
- SolidCacheCoordination against real Solid Cache private APIs.
- Live adapter behavior behind mocked transports: Qdrant, pgvector, Notion, Unblocked, Ollama, OpenAI.
- INF-2's starvation window end-to-end (mechanism traced; a live demonstration needs a >600s extraction harness).

## What could not be verified, and why

- **Booted-app lanes.** The Docker testbed is not available in this environment and the brief forbids booting Rails on the host. Not executed: incremental equivalence oracle, booted extraction across the Rails matrix, watch-daemon integration, multi-worktree, G-1 wrapper fixtures on live Zeitwerk, runtime-introspection extractor paths, console transports on a booted host. Findings depending on these carry [traced] and the lane is named at each.
- **Live backends.** No Qdrant, PostgreSQL, Redis, MySQL, or embedding service here. STO-2's Qdrant half is executed at the Indexer level with a fake durable store and traced through the adapter's pinned specs. CON-2's MySQL-host consequence is executed at the validator level, not against a live server.
- **Windows filesystem behavior** (EXP-9's reserved-name half): inference.
- **Real-host frequency estimates** for comment shapes (EXTA-1), STI prevalence (EXP-1), and overlap pressure (MCP-5): the mechanisms are executed; the prevalence claims are judgment and labeled at each finding.

## Environment notes that shaped evidence

- This environment runs under a POSIX locale, which is the repo's documented live canary. That made the encoding-family findings directly observable (R2-3 fails the stock suite here).
- This environment runs as root, so three chmod-based permission specs cannot fail here; recorded in 06, not findings.
- Budget: within the expected range; all ten passes completed; no slice was dropped.

## Assumptions recorded

- The audit target is `origin/main` at `79c156d`. The session's designated branch held only history already merged via PR #210 and was restarted from main per the merged-branch rule.
- The prior audit folder is not in the repo tree at HEAD; the uploaded archive of `v2-prerelease-audit/` was treated as authoritative for ledger content.
- Severity conventions follow the prior audit: High = breaks a primary tool or contract under realistic conditions, or silently corrupts or leaks. Prevalence judgments are labeled [inference] where they carry a rating.
- "Two generations of finding IDs" (the original ledger and the #269/#270 tail set) are kept distinct throughout; tail IDs are written tail-M*.

## Working-tree discipline

`git status -sb` verified clean before and after every phase. No repo file outside `docs/self-analysis/v2-audit-2/` was created or modified. Scratch probes live only in the session scratchpad.
