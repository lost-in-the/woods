# Offline pre-push review fixture kit

This is a six-candidate development fixture kit for checking whether a reviewer
can identify concrete behavior failures in a proposed Ruby change. It contains
three paired defect/valid families derived from resolved public Woods fixes.
It is not a PR-comment predictor, a historical commit replay, an accuracy
benchmark, or evidence that TypeSafe has reviewed anything successfully.

The entire directory is portable. It needs Ruby 3.0 or later and only standard
libraries. It does not load Woods, boot Rails, call TypeSafe, access credentials,
or require Git. It executes its trusted local fixture source in temporary module
namespaces and uses disposable directories for filesystem checks. It is not a
sandbox for executing arbitrary downloaded code.

## Validate the kit before using it

From the directory containing this README:

```bash
ruby evaluate.rb > evaluation.json
```

The output is evaluator-only JSON. Exit status `0` means all six fixtures show
their intended behavior: three regressions are reproduced, three valid changes
satisfy the oracle, all shared baselines satisfy the oracle, and all candidates
pass their visible smoke tests. A reproduced defect is a successful *fixture*
validation, not a successful review. Exit `1` means an unexpected behavioral
outcome; exit `2` means fixture integrity, loading, or another infrastructure
failure. Individual candidate failures do not suppress the remaining cases.

Every case file has an SHA-256 digest in `evaluator/cases.json`. The evaluator
refuses modified inputs. That catches accidental edits and extraction damage;
it is not an authenticity signature. To intentionally develop a new fixture,
regenerate its patch and digests and independently revalidate its expectations.
Do not silently rewrite the frozen case before reporting a reviewer result.

## Give the reviewer one neutral packet

```bash
ruby packet.rb 7d43a9f1 > /tmp/review-packet.json
```

Available opaque IDs are `7d43a9f1`, `9b0e27d4`, `c59a814e`, `f108d3b6`,
`2e614c8a`, and `a83f260d`. Each packet includes:

- a neutral task describing the module's required behavior;
- the complete shared `before.rb` and proposed `source.rb`;
- a nonempty unified `change.patch` targeting `source.rb`;
- the complete existing `test.rb`, including assertions;
- the shared MIT license, so redistributed snippets retain their attribution.

`packet.rb` reads the selected `cases/<id>/` directory and shared license. It does not read
the evaluator manifest or any label. Packet filenames do not say which candidate
is defective. Both members of a family have identical requirements, baseline,
and visible tests; both propose actual source changes. The provider should see
one packet at a time in a fresh conversation. Keep every candidate's test context
through localization, mechanism checking, and final judgment.

**Do not send this README, `evaluator/`, `evaluation.json`, sibling candidates,
or these fixtures' provenance to the reviewer.** An agent with access to the
whole directory can discover the labels; separation here is procedural. For a
meaningfully blinded run, give it only exported packet JSON, disable unrelated
filesystem/history access, and keep the answer key with the evaluator.

Suggested review instruction:

> Review the proposed source change using the supplied requirements, full source,
> patch, and tests. Report only actionable correctness findings. For each finding,
> give the affected source lines, a concrete input or state, observed versus
> required behavior, and the causal code path. Return an empty findings list if
> you find no actionable issue. Passing existing tests is evidence, not proof of
> completeness. Do not change the code before recording your findings.

Store the exact request, response, chosen model, settings, latency, input tokens,
output tokens, and cost alongside the candidate ID. Evaluate a finding on its
trigger and causal explanation, not matching words from the answer key. A generic
"add edge-case tests" response does not demonstrate discovery of the defect.
Report misses and false alarms separately. Compare the same evidence packet with
your normal agent review so a cheaper equally useful result counts as a benefit.
Do not infer capability or inability from one synthetic family or one draw.

## Evaluator-only origins and adaptations

The exact original repository, source paths, parent revisions, and fixing
revisions are pinned in `evaluator/cases.json`. MIT attribution is retained in
`LICENSE.txt`. All source is adapted from public Woods code or newly authored
fixture scaffolding. No application/employer source or private PR data is used.

| Family | Public source | Minimized behavior under review |
|---|---|---|
| Cache arity | Woods fix `b67198737cdc98219665ece514487027dc2b0168` | One-component fast path can alias an encoded multiple-component sequence, including after hashing. |
| Snapshot retention | Woods fix `614b2613063f26d2ffa7629e8ace3ba9b98940e0` | Enumeration that omits unreadable JSON lets eligible snapshot files escape the retention bound. |
| Named routes | Woods fix `cc3bd3eae5cbecb398cb208006037fe7492b432a` | Prefix suppression can override an authoritative named route and erase a real navigation relationship. |

The fixing revisions establish the public origin of the mechanisms. Candidates
are **newly assembled changes from shared baselines**, not exact snapshots of
those original PRs. This makes each oracle demonstrate a regression introduced
by the proposed candidate, rather than rewarding detection of an unchanged bug.

Cache candidates retain the original length threshold, namespace, string
conversion, hashing, and faulty/correct encoding decisions. The shared baseline
uses an unambiguous JSON array instead. This fixture restricts domains to the
internal symbols `:search` and `:metadata`; an identical guard in both baselines
and candidates rejects every other input. Components remain unrestricted strings
after conversion and may contain colons. This added fixture boundary does not
claim that Woods itself enforces the restriction or that the unescaped domain
encoding distinguishes arbitrary domain strings. No cache backend is needed: the returned
key bytes demonstrate whether two distinct requests would share an entry. The
oracle checks zero versus one empty component, single versus multiple components,
and the hashed long-key path.

Snapshot candidates retain physical JSON files, malformed/non-object input,
filename ownership, retention overflow, and newly captured snapshot protection.
They omit unrelated temporal diff/history functions and production atomic-write
infrastructure. The common baseline counts all eligible files; candidates alter
summary enumeration and ordering. The oracle uses malformed JSON, arrays, and
null, preserves a newly captured older timestamp, and confirms unrelated files
and snapshot-shaped directories are untouched. It does not model concurrent
writers, disk failures, or permission behavior.

Route candidates receive an already resolved runtime map. They retain the
original helper suffix match and the faulty prefix-filter precedence; the
baseline uses Ruby suffix removal. The oracle checks path and URL spellings for
ordinary and prefix-like route names and omission of an unknown helper. This
isolates a post-reflection decision; it does not establish that a Rails route
extractor populated the map correctly. That needs a separate booted Rails test.

## What this establishes and what remains

These executable checks establish that the supplied evidence contains three
specific regressions, their controls behave correctly on the tested contract,
and the visible tests alone miss the regressions. There are no mocked return
values standing in for the behavior under test. Source syntax and successful
loading are prerequisites, not the defect oracle.

The kit is small, intentionally understandable, and uses explicit requirements.
It tests workflow plumbing, evidence retention, localization, and false-alarm
handling. It cannot estimate production precision/recall, discover realistic
Rails context limits, or validate performance/security comprehensively. Follow a
successful smoke run with untouched current changes and real runtime packets;
keep those findings independent of these known examples. Do not expand a PR
corpus as a prerequisite to trying the actual pre-push reviewer.
