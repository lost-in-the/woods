# Jev Rails review: assessment and independent-verification prompt

Reviewed 2026-09-19. This document reviews the supplied **Jev Rails Review —
Implementation Handoff** and **Rails Reviewer Question Bank (Jev)** against our
existing pre-push work, small local reproductions, and current primary documentation.
It is sanitized for sharing with another project. It contains suggestions, not an
approved implementation specification or a finding that Jev succeeds or fails at
code review.

## Assessment

**The question bank offers a useful, more concrete way to try direct Jev review.**
It turns many common Rails review concerns into reusable questions and identifies
some of their evidence requirements. It could reduce the need for an expensive
reasoning model to invent every candidate concern. The sections on local codebase
conventions, jobs, callbacks, rollout, and tests are especially relevant to mistakes
coding agents make.

This develops a direction already present in our earlier plan—direct judgments
about changed behavior—rather than supplying new evidence of model effectiveness.
The supplied material contains illustrative answers and proposed code, not a
measured reviewer trial. Its chart and automatic gates need substantially more
work than its basic question-bank idea.

My suggested combination is: preserve the breadth of the bank, supply trustworthy
Woods/source/test evidence, ask coherent checks in batches, then investigate
specific supported concerns. Keep the chart as an optional overview. Verify this
combination experimentally rather than accepting it because it resembles our
previous recommendations.

## Evidence levels used here

- **Reproduced:** a local computation or minimal Ruby example demonstrated the
  stated behavior. This establishes that behavior of the printed example, not a
  defect in an unseen implementation.
- **Document inspection:** the supplied text/code contains the stated mismatch
  or omission. The actual project may already implement the missing piece.
- **Primary-documentation check:** current provider/framework documentation
  supports the correction. Check the project's actual versions and configuration
  before applying it.
- **Hypothesis:** a plausible benefit or failure mode requiring a representative
  experiment. It must not be presented as an established result.

No TypeSafe inference ran for this assessment. No API key was retrieved, no
application code was changed, and no GitHub issue or comment was created. Small
Ruby probes exercised only the relevant expressions using synthetic inputs.

Input fingerprints, so another agent can identify the exact drafts reviewed:

```text
Implementation handoff SHA-256:
2d83f584d23517f6beb1a20254f6a1ee4ddfdefb0aab96aaf5e34b37b423decd

Question bank SHA-256:
0cd36835707f2d354b96ee480927f54dfd22ce88585f0041cbb860c9e10a8004
```

## What seems worth adopting or testing

| Proposal | Potential value | What would establish that value |
|---|---|---|
| Versioned Rails question bank | Repeatable review coverage without asking a large model to invent every hypothesis | Actionable findings on current changes, plus fewer misses or lower total review cost |
| Broad parallel questions | More cheap opportunities to notice a defect | Compare broad and focused batches on identical cases; retain actual usage and latency |
| Explicit context requirements | Makes missing evidence an engineering problem we can inspect | Show each check's required inputs, their provenance, and what was unavailable |
| Comparison with local equivalents | Could catch agents bypassing project helpers, contracts, or conventions | Compare an actual comparable sibling with arbitrary same-directory siblings and no sibling |
| Job/transaction/callback/rollout checks | Targets behavior that can be valid syntax yet fail in operation | Defect/control pairs with executable or independently justified mechanisms |
| Typed judgments and a reusable ledger | Results can support different presentation policies without repeated inference | Preserve raw responses, input identities, question versions, and investigation outcomes |
| Feedback during development | Could correct an agent before a mistake spreads | Measure usable feedback and interruption cost at coherent edit checkpoints |

TypeSafe documents shared-state parallel evaluation, and its batching cookbook
reports savings in one document-question experiment. That supports testing broad
batches, without establishing the latency or correctness of this Rails bank.
[Parallel-questions cookbook](https://docs.typesafe.ai/cookbooks/parallel_questions).

Current published pricing is $0.042 per million input tokens, with free output.
For scale, **20,000 total billed input tokens cost $0.00084**. This is arithmetic,
not an estimate of this bank's actual usage. Log returned usage and include retries,
retrieval, and other-model work in total cost. The documented current model is
`jev-1.13.0`; the limits are 64k for the whole request and 32k for state plus the
longest question. The handoff omits the whole-request limit. Pin and record the
model version for comparisons. [Model reference](https://docs.typesafe.ai/models).

The low price is a reason to give broad semantic checks a fair trial. It is not a
reason to discard relevant code to fit an unnecessarily large common state. The
appropriate tradeoff may be more questions, several focused states, or a shared
complete state; we have not compared those alternatives on this bank.

## Corrections to verify before using the draft unchanged

### 1. Positive signals are not consistently distinguished from faults

**Reproduced/document inspection.** `test_coverage_of_change` has its strongest
coverage at level 3, so the generic normalization maps good coverage to 1.0. If
the handoff's high-bar blocking rule is applied uniformly, it treats this as a
bad outcome. Conversely, no touched tests map to zero. The separate Noul
`test_regression_for_fix` asks whether a useful regression test exists, while the
generic findings code treats high Nouls as problems.

Consider recording explicit direction and meaning per question. Keep positively
worded criteria aligned with their instructions; handle display polarity in code,
or rewrite the question itself clearly. Do not silently turn every measurement
into a fault probability. Also distinguish tests changed in this diff from all
existing tests relevant to the changed behavior.

### 2. Some questions detect a pattern, without establishing that it is wrong

**Document inspection; likely impact is a hypothesis.** A valid framework choice,
intentional bypass, existing authorization layer, or project convention can make
the literal answer yes while there is no actionable defect. Examples include
adding STI, using a concern in one class, returning nil, finding by an ID before
policy authorization, and relying on an intentional default scope.

Separate observable facts, correctness concerns, and project preferences. A style
question can be useful when the repository actually adopts that rule. It should
not be counted as a correctness catch merely because a named reviewer might
prefer another design. The persona names are organizational labels, not proof of
independent specialist review.

For consequential checks, consider questions about the actual contract: whether
this write bypasses a callback needed to maintain a named invariant; whether the
shown authorization path permits a prohibited access; whether retrying this
operation creates a forbidden duplicate effect. Verify that this extra specificity
helps rather than presuming that all broad questions must be replaced.

### 3. The proposed state does not meet the bank's evidence needs

**Document inspection.** The state builder supplies a diff, touched files, a few
siblings, churn, a schema slice, description, and commit messages. Several bank
questions additionally need caller/reference evidence, relevant unchanged tests
and support, inherited behavior, deployment state, line age, runtime configuration,
local policies, or helper-search results. `referenced_constants` is a stub, so
its churn input is empty.

State construction should distinguish present, absent, omitted, and unknown.
Missing context should not silently become “no problem.” File presence also does
not prove sufficient semantic evidence: a job class alone may not reveal the
external system's idempotency contract.

### 4. The schema helper demonstrably discards the definitions

**Reproduced.** The capturing group in `String#scan` returns table-name captures,
not whole matching schema blocks. On a synthetic table with an index, the printed
helper produces `"orders"`; the index information is absent:

```ruby
schema = <<~SCHEMA
  create_table "orders", force: :cascade do |t|
    t.bigint "account_id"
    t.index ["account_id"], name: "index_orders_on_account_id"
  end
SCHEMA
tables = ['orders']
result = schema.scan(/create_table "(#{tables.join('|')})".*?end$/m).join("\n")
p result                         # "orders"
p result.include?('index_orders') # false
```

Fixing that capture is necessary but does not solve model-to-table resolution,
namespaced/custom table names, migration-only changes, or `structure.sql` projects.
Use actual resolved schema information where available and explicitly selected
schema/migration source. Do not evaluate `perf_missing_index` as if the current
helper had supplied the indexes.

### 5. Revision identity and file identity can disagree

**Document inspection.** The diff uses a base/head range, while `File.read` reads
the current working tree. These can describe different versions. Deleted files
also fail that read; line-based path enumeration mishandles newline-containing
paths. Git command failure is not checked.

Consider separate committed-range and working-tree modes, with explicit snapshots,
before/after source, and NUL-safe path enumeration. Our existing extraction receipt
can check declared local source/producer/index bytes, but it does **not** implement
Git snapshot selection or authenticate Git identity for this tool.

### 6. The edit hook is not runnable as printed

**Reproduced/document inspection.** The path regex accepts relative `app/...`,
`lib/...`, or `db/migrate/...` paths, so an absolute path fails it. The hook calls
`State.siblings_for` as a class method, but the sketch defines it as a private
instance method. Its state contains `file`, while reused instructions name `diff`.
The schema of each edit-time question therefore needs checking too.

The official hook contract confirms absolute file paths and that PostToolUse runs
after the operation. Its feedback does not undo the edit. Hooks matching Edit/Write
also do not cover every way a shell command can mutate files. Verify installed
client behavior before relying on a hook as complete change capture.
[Claude Code hook reference](https://code.claude.com/docs/en/hooks#posttooluse).

A one-file edit may be an intermediate step in a valid multi-file change. A
debounced, content-addressed advisory check at a coherent checkpoint is worth
comparing with per-edit checks. Sub-second behavior is a target requiring
measurement, not something established by the example client.

### 7. Parallel answers are not a reasoning chain

**Primary-documentation check plus design inference.** Questions share state but
do not see one another's answers. The headline Score is not calculated from the
Nouls, and those Nouls are not an explanation of that score. A Choice returned in
the same request is not input to another question. Conditional checks should state
their premise independently, or receive prior answers in a later request.
[Question semantics](https://docs.typesafe.ai/primitives).

For example, the bank's annotation `change_kind = fix` is insufficient by itself
to condition another question in the same request. Likewise, a mismatch between
`primary_concern` and one headline bar is diagnostic material, not proof that one
is miscalibrated. The questions can ask materially different things.

### 8. Confidence and the chart do not justify the proposed gates

**Primary-documentation check/document inspection.** Confidence describes an answer's
distribution, not guaranteed correctness. Low confidence can reflect missing
evidence, ambiguous criteria, or mixed behavior. The handoff's claim that it usually
means wording overlap is too narrow. Silencing uncertain important checks would
hide incomplete review; record them and decide whether to gather context or defer.
[Confidence guidance](https://docs.typesafe.ai/confidence).

Dividing each Score by its top level changes display range, not the meaning or
comparability of the underlying dimensions. A large intended user-visible change
is not equivalent to a data-loss defect. Multiplying by reviewer weights can also
produce values above 1.0, despite the normalized-bar description.

The opening advisory-only promise conflicts with the later PR/hook blocking table.
The numerical gates, including `disposition = rework`, have no validation supplied
here. Advisory-only is my suggested initial posture; a later gate should depend
on observed error costs and quality. These are implementation-policy suggestions,
not universal prohibitions on using thresholds.

### 9. The large common state and truncation policy need an actual comparison

**Primary-documentation check and hypothesis.** Jev's current limitations page
warns about irrelevant context, indirect questions, literal interpretation, and
unguaranteed identities across separate questions. It was reachable during this
review. These support trying coherent evidence packets, without proving that a
full-bank request will underperform.
[Jev 1.13 limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13).

Do not assume that line count predicts token fit. The request includes full touched
files as well as the diff. Cutting the tail of the diff to preserve three siblings
can remove the actual defect. Prefer an explicit included/omitted inventory,
complete relevant definitions and tests, and meaningful review units when splitting.
Compare a valid full-bank request against family-specific state on the same cases.
Preserve the full bank as a coverage catalog even if inference is grouped.

### 10. Rails semantics need version- and adapter-aware criteria

**Primary-documentation checks.** These are examples to verify, not an exhaustive
audit of every Rails assertion in the bank:

- `ar_skips_validations` includes `toggle` among persistence examples, but non-bang
  `toggle` changes the object without saving. `update_attribute` skips validations
  while invoking callbacks; `update_columns` skips both. `touch` has its own callback
  behavior. Check the precise method and invariant rather than treating this list
  as one behavioral category. [Rails 8 persistence API](https://api.rubyonrails.org/v8.0/classes/ActiveRecord/Persistence.html).
- Passing an Active Record object is supported by Active Job's GlobalID mechanism.
  Sidekiq-native argument requirements and Active Job behavior need distinct rules.
  [Active Job argument support](https://guides.rubyonrails.org/active_job_basics.html#globalid).
- Enqueueing inside a transaction does not alone prove that execution can precede
  commit. Inspect the job, adapter, version, and effective deferral settings.
  [Rails 8 enqueue configuration](https://api.rubyonrails.org/v8.0/classes/ActiveJob/Enqueuing.html).

A high probability for an inaccurately defined rule can still be a correct answer
to the literal question. Reproductions should isolate a model mistake from a bad
rule or missing runtime evidence.

### 11. The question inventory and response plumbing need basic validation

**Reproduced/document inspection.** The supplied table has **204 question rows:
185 Noul, 16 Score, 3 Choice**, with no duplicate IDs. Its changelog says 203/184.
The `ar_find_by_memoized` question is cut off. Only 32 rows explicitly mark extra
context, although additional rows need it. Change hygiene has no dedicated
headline Score, while Rollout has two; the generic one-headline-per-section rule
therefore needs an explicit mapping.

The Ruby client discards returned usage and model identity, does not distinguish
HTTP errors, and does not validate answer coverage/types. It also has no bounded
retry policy for transient responses. These are missing implementation details,
not evidence against the overall approach. Preserve the entire response plus timing,
request/question/state hashes, failures, and retries. The endpoint and basic typed
request shape in the sketch agree with the current API.
[API reference](https://docs.typesafe.ai/api).

### 12. Agreement, correlation, and calibration need narrower interpretations

**Methodological judgment, not a completed experiment.** Linter/model agreement is
useful corroboration, not free ground truth. They may share an overly broad rule.
Disagreement needs investigation; either can be wrong, or they can be answering
different questions. Correlated Nouls are not necessarily duplicates: query-in-loop
and association N+1 can have different counterexamples and remedies.

Historical PRs can be useful examples, especially if carefully reconstructed. They
are not necessary before trying this reviewer. The proposed cycle of repeatedly
editing questions until disagreements disappear risks tuning to known examples.
Keep development cases distinct from untouched checks. The sample absolute-error
threshold also means different things for a probability and a multi-level Score;
do not treat it as one quality metric.

## How Woods could improve this implementation

Reuse actual resolved Rails evidence when the check needs it: callbacks and concern
source, associations and table identity, controller inheritance, relevant schema,
and selected tests/helpers. Fill unsupported facts explicitly from source or a
separate check; do not claim Woods already emits every effective runtime setting.
Use graph records to select candidate context, then inspect the physical source.

The repository has advanced since our September 17 capture. Current docs describe
typed `reverse_via` records, explicit lexical retrieval, and graph-coverage and
traversal-budget disclosures in supporting versions. These can help context
selection and honest missing-evidence reporting. They do not turn references into
an exhaustive call graph. Verify the installed version and connected schema rather
than assuming the current repository's surface is shipped everywhere.
[Index layout](https://github.com/lost-in-the/woods/blob/2885f755/docs/INDEX_LAYOUT.md),
[agent guide](https://github.com/lost-in-the/woods/blob/2885f755/docs/AGENT_GUIDE.md).

For future edit-time integration, inspect the existing version-gated Woods
adapters and refresh/publication contract. A completed hook handoff is not proof
that the matching generation is ready to review. Avoid creating a second refresh
path without understanding the first.
[Client hook contract](https://github.com/lost-in-the/woods/blob/2885f755/docs/CLIENT_HOOKS.md).

Our exported packet and receipt are development tooling, not a complete reviewer.
They preserve selected physical files, typed units, declared input hashes and a
generation. They do not automatically select all relevant tests, capture a diff,
verify the full runtime environment, or prove behavioral coverage. The Woods
self-map helps with Woods source ownership; it cannot supply live Rails facts.

## Bias audit: why these suggestions might be wrong or over-applied

| Prior influence | Why it influenced this review | Limit and way to challenge it |
|---|---|---|
| The user clarified that review catches were guidance for pre-push review, not a requirement to mine old PRs | I prioritize an actual current-change review output | That does not make historical examples useless. Use them if they cheaply test this design, without turning corpus work into a prerequisite |
| Earlier work overemphasized PR-level prediction | I distrust an aggregate chart as the primary success criterion | A multi-axis chart can still help navigation. Compare its usability; do not discard it merely because another scoring experiment failed |
| Our earlier adapter/context problems | I prioritize complete assertions, typed identity, freshness and missing-context disclosure | Some failures were orchestration defects. They cannot be generalized into Jev limitations or assumed to exist in the other agent's implementation |
| Preference for narrow checks and small coherent packets | Precise contracts are easier to debug, and current docs warn about distracting state | We have not tested this 204-question bank. A broad shared-state pass may work well; keep it as a measured comparator |
| Preference for actionable correctness findings | The stated goal is to improve review before pushing code | Convention checks may also save effort. Judge their utility separately rather than declaring them worthless or counting them as correctness bugs |
| Skepticism about unvalidated automatic gates | No validated thresholds or error-cost evidence accompanies these drafts | This supports an advisory prototype, not a permanent ban on automation. Reconsider when evidence supports a gate |
| Previously used fixtures and runtime packet | They provide working export/oracle infrastructure | The six portable candidates are three small generic Ruby families, not a representative Rails benchmark. The runtime packet contains context, not a labeled change |
| TypeSafe's very low token price | Broad screening and extra diagnostic calls may be economically useful | Include total workflow cost and human attention. Do not reject a design for small token inefficiencies or accept it solely because calls are cheap |

Our fresh September 17 Rails capture verified selected callback facts, but it used
producer `c025434f`. It does not validate all subsequent Woods revisions or the
new question bank. The full-suite and fixture results from that work establish
local tooling behavior, not TypeSafe's defect-detection accuracy.

A receiving agent should also challenge my framing. My interpretation of the
user's current objective, the distinction between preference and defect, and the
choice of first cases may be incomplete. Where the documents are only sketches,
check the actual implementation before treating omissions as outstanding work.

## Suggested experiment, subject to the receiving agent's verification

Start with the smallest set of representative changes that can distinguish the
competing designs. Candidate families include callback/validation bypass,
inherited authorization, job retry/commit visibility, and serialized or cached
state compatibility. Include valid counterparts and deliberately incomplete
context. Use the public Rails testbed where it provides the necessary behavior.

After fixing mechanical bank/client defects, consider three comparable review
paths on the same admissible evidence:

1. A direct Jev pass using the applicable bank with a complete shared state.
2. The same checks grouped around focused evidence, with further context requests
   recorded instead of silently suppressing uncertain results.
3. The ordinary reasoning-agent review used today.

Use the existing generic fixture kit for workflow smoke checks, not as the only
test of Rails expertise. Preserve direct Jev results before another model explains
them. Confirm findings by their location, trigger and mechanism, with executable
counterexamples where feasible. Compare misses, false alarms, incomplete review,
total cost and latency. Do not tune repeatedly on all cases and then call the same
cases validation. A small pilot can justify a next step without estimating
production precision or recall.

## Copyable prompt for the receiving agent

```text
Please review the attached Jev Rails question-bank assessment as a set of
suggestions from another agent. Do not accept its factual claims, priorities,
or proposed design merely because they are stated confidently.

My understanding of the user's objective is to improve review of new code before
it is pushed, especially mistakes coding agents make. Earlier references to
issues caught in code review were intended to help choose failure modes, not to
require historical PR-comment prediction. Verify that this interpretation still
fits the task you are actually implementing. If your current assignment or the
available evidence suggests otherwise, explain the difference.

First inspect the actual implementation, if one exists, alongside both original
drafts. Distinguish unfinished illustrative snippets from defects that remain in
the real code. Reproduce the mechanical claims where practical: question count
and truncated wording, score/Noul polarity, schema extraction, absolute-path
handling, class-versus-instance method access, and state-field consistency.
Check the current TypeSafe contract and the Rails/client versions in this
project. Documentation changes and project-specific configuration may invalidate
a correction in this assessment.

For each material suggestion, record one of: verified, partly supported,
unverified, rejected, or already addressed. Give the evidence and practical
consequence. You do not need to reproduce every prose observation or accept the
proposed experiment unchanged. Prioritize claims that can change the outcome of
a review. If you reject a suggestion, state why and what approach you prefer.

Please specifically examine whether the question bank lets Jev do useful direct
semantic review, without a larger model first doing all the discovery. Its broad
coverage may be an advantage. Do not narrow it simply because this assessment
prefers coherent packets, and do not assume a single all-question request is
best simply because batching is cheap. Compare valid alternatives on the same
cases where that distinction matters. Questions sharing state run independently;
any dependency between answers must be implemented explicitly.

Separate pattern presence, project convention, supported defect mechanism,
impact, and evidence sufficiency. Check that the questions actually mean what
the report claims they mean. Give framework version, adapter, inherited behavior,
and complete relevant tests their proper role. A supported framework pattern
should not become a bug merely because an overly broad rubric says so. Equally,
do not remove useful style or convention feedback if the project benefits from it.

Consider reusing Woods' current source/index evidence and the existing packet and
receipt tooling, but verify their contracts. They do not supply complete source
coverage, all runtime configuration, Git snapshot selection, or automatic test
discovery. An older capture with good checks is still an older capture. Use the
correct source and producer version for any new behavior-dependent experiment.

Treat the previous conversation and previous experiments as fallible background.
Some earlier negative results may have measured the wrong target, used incomplete
evidence, suffered adapter errors, or lacked enough valid controls. They are not
proof that Jev cannot review code. The opposite conclusion is not established
either. Our existing small Ruby fixtures and successful Rails extraction do not
demonstrate that this bank detects Rails bugs.

My suggestion is an advisory local prototype before blocking hooks or CI rules,
because validated thresholds and error-cost evidence have not been supplied.
Verify that premise. If a gate is already supported by good project-specific
evidence, evaluate that evidence rather than preserving advisory-only behavior
as dogma. An uncertain or incomplete check should remain visible in the ledger;
it should not silently become a clean review.

Use TypeSafe's actual low price when judging value. Current published input pricing
is $0.042 per million tokens with free output; verify it at execution time. Broad
fan-out or extra checks may be worthwhile. Measure all request usage, retries,
other-model work, latency, and reviewer attention. Do not optimize token count at
the expense of preserving the code and assertions needed to find the bug.

If proceeding to tests, choose representative current changes or controlled
defect/valid pairs with an independent behavioral basis. Historical PRs may be
used when helpful, but collecting a large corpus need not precede a working
reviewer. Keep development and untouched cases distinct. Preserve direct Jev
outputs, and show what it contributes beyond the normal-agent comparator.

Please return:
1. A concise verdict on the feedback, including anything you disproved or think
   is biased or inapplicable.
2. The smallest justified implementation adjustments, with evidence for each.
3. A representative review result or bounded experiment that tests the actual
   proposed benefit, if implementation/testing is within your authorized task.
4. The remaining uncertainties and what would change your recommendation.

Do not let this review become another long planning prerequisite. Once the
material assumptions are checked, use your judgment to make a useful experiment
or demonstration. This prompt itself does not authorize GitHub writes, sharing
private project data, installing blocking hooks, or changing production behavior;
use the permissions already established in your own session.
```
