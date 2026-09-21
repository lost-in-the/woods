# Bounded evidence investigation: prospective pilot

Version `2026-09-21.1`. Freeze this protocol, question definitions, code, fixture
manifest, source cards and source/revision receipts before any provider request.
The old six-question and 204-question experiments remain unchanged.

## Question and scope

Can Jev choose useful supporting source and improve focused judgments when a
review begins with an incomplete evidence packet? This tests a bounded evidence
selection workflow, not autonomous code writing or a production pre-push gate.

Use four new booted Rails defect/control pairs, eight candidates, two provider
repeats per candidate. None of the previous twelve pairs is an untouched holdout.
Every new pair has a private executable mechanism oracle and legitimate control.
Curated menus still limit the candidate universe: success is not evidence that
the runner can discover arbitrary missing files in a production application.

## Shared inputs and arms

Initial evidence contains the full changed source, diff, stated intent, captured
runtime premises and a menu of available supporting cards (opaque ID, physical
path and source kind). Supporting bodies remain behind the inspection operation.
Private labels, oracle outcomes, necessary-card IDs and family target mappings
never enter provider state. Preserve one generation per candidate, exact source
hashes, captured freshness, checked-out SHA and intended range independently.

Both arms share the same initial full-bank call per repeat. Preserve all 204
answers. A compact signal list may aid navigation but does not become a whole-
change probability or a correctness verdict. Routing hints contain at most eight valid defect Nouls,
ordered by directed probability then identifier, whose declared requirements are
supplied. Apply the retained Tests/Views path premises. A menu entry does not
supply its body; implicit missing premises remain possible. No Score or convention
enters those hints. The initial bank cannot assess requirements whose evidence
is not present.

- **Static enrichment:** select up to two cards using a frozen deterministic
  direct-reference/path heuristic: direct CamelCase constant matches first, then
  file-stem token overlap with changed source and stated intent (snake_case and
  CamelCase split), then path/ID lexical ties. It may read changed source, intent
  and menu, not
  private labels or unopened supporting bodies. Then ask the focused questions.
- **Jev enrichment:** use a Choice to select a card or `stop`/`need_context` from
  the currently available actions. Code validates the ID and reads that exact
  frozen card. Repeat at most twice, showing the newly observed state to the
  second selection. Then ask exactly the same focused questions as the static arm.

This compares evidence-selection policies under a two-card upper bound. The
adaptive arm may stop early; report actual inspections. An invalid routing answer
does not become a fabricated selection. Record a stopped/unassessed outcome or
the explicit deterministic fallback separately; no hidden fallbacks or retries.

The focused questions separately ask whether the supplied evidence demonstrates
a concrete violation of the stated contract, whether essential evidence remains
missing, which predefined broad mechanism fits (`none` and `unknown` included),
and which supplied source location supports the concern (`none` included).
Choices select among supplied options; they do not generate explanations. A high
severity or pattern judgment cannot establish the premise that a defect exists.

## Execution and interpretation

Use pinned `jev-1.13.0` with no automatic retries. Load a credential once per
capture process, save no key value, and account for every attempted request even
if answers or usage are malformed. Reuse existing strict per-answer validation
and bounded rounding diagnostics. State-plus-longest-question and whole-request
preflight use the retained conservative 30,000/60,000 UTF-8-byte proxies; they are
not provider token counts. Never truncate distinguishing source to fit.

Randomize candidate/repeat jobs with seed 2026092107, and alternate which arm
performs its focused stage first. Each paired job shares exactly the same captured
initial scan. Two repeats are descriptive and
correlated, not independent application samples. Freeze all action/question definitions and selection policies before
responses (actual selections remain adaptive); preserve misses and avoid prompt tuning on this set. Actual calls vary
when an adaptive arm stops. Shared initial-scan cost is recorded once in actual
totals and attributed to each hypothetical standalone workflow explicitly, never
double-counted as actual spending.

Report necessary-card retrieval as a separately labeled diagnostic; oracle-defined
cards are not necessarily the only valid evidence. Report focused contract
probabilities, invalid/missing answers, control leads, selected source, stop
decisions, source bytes, latency and actual token usage. Inspect every claimed
mechanism against source and executable receipts before calling it confirmed.
Do not equate model self-reported evidence sufficiency with actual sufficiency.

Primary high-lead band is contract Noul >= 0.8 with valid non-`none`/non-`unknown`
mechanism and supplied source selection. Missing/unknown context stays visible;
this is advisory navigation, not a merge decision. Report a separate offline
necessary-card coverage diagnostic using the private fixture manifest, including
whether a high lead lacks those cards. The private diagnostic never drives the
routing, eligibility hints or model state and is not proof that no other evidence
could suffice. Coordinator source/oracle adjudication is required for a confirmed
finding; model sufficiency cannot grant that status. Preserve all component answers
so a composition failure is distinguishable from a useful underlying signal.

This initial pilot measures selection and typed follow-up behavior. Coordinator
verification is not a blinded reasoning-reviewer comparison; no downstream token
savings or tokens-to-first-finding result is claimed without separate telemetry.
An installed-app companion and a larger blinded comparison remain separate work.

## Sources

- [TypeSafe API](https://docs.typesafe.ai/api)
- [Speculative fan-out](https://docs.typesafe.ai/patterns/fan-out)
- [Function calling](https://docs.typesafe.ai/cookbooks/function_calling)
- [Guide chapter 11](../../../docs/design/typesafe-agent-guide/11-full-bank-review-lessons.md)
