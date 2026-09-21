# Architecture and operations

Keep TypeSafe behind an explicit evidence-selection boundary. Ordinary code discovers candidates, verifies source identity, constructs typed questions, validates the entire answer vector and applies policy. A coding agent can then consume selected source; execution and behavioral testing remain separate. The [portable example](examples/README.md) implements the boundary through ranking and stops there.

## Contracts between stages

| Stage | Input and output | Owner |
|---|---|---|
| Snapshot | Immutable source bytes plus one index generation | Woods/application adapter |
| Discovery | Task → finite, traceable source candidates | Deterministic search/retrieval |
| Judgment | Allowlisted state + independently meaningful Noul questions → typed probabilities | TypeSafe |
| Validation | Exact question IDs, model, values, usage and provenance → complete usable vector or failure | Client code |
| Selection | Scores + explicit ties/budget/fallback → delivered source with byte coordinates | Application policy |
| Implementation | Task + delivered evidence → proposed edits | Separate author |
| Acceptance | Reviewed exact edits + isolated application → behavioral results | Deterministic evaluator and reviewer |

The API accepts a state and a question map. Questions over that state are independent; one question cannot consume another's answer in the same request. Question IDs link responses to code, so instructions must explicitly reference the relevant state. A Noul is the probability of yes, with no separate confidence field. See the current [HTTP API](https://docs.typesafe.ai/api), [state guidance](https://docs.typesafe.ai/concepts/state) and [Noul contract](https://docs.typesafe.ai/primitives/noul).

Use a second request when an earlier answer genuinely determines which new evidence to fetch. Reuse a validated vector when only a deterministic budget, display ordering or policy weight changes. Reuse is appropriate only while the task, evidence and question meanings remain identical.

## Candidate and freshness contract

Every candidate should identify its source file and exact byte span, with hashes for both the whole file and the supplied slice. Keep completeness/truncation explicit. A method name without its source identity is insufficient: the same name can occur in several files, and the same string can occur more than once in a file.

Woods' published generation identifies a coherent index snapshot; it does not magically freeze the checkout the author will edit. Preserve both index and source identity. For Rails behavior use a booted application extraction; the Woods self-map provides conservative static source orientation. See [Woods integration](05-woods-integration.md) for the adapter boundary.

Validate freshness before inference, before later requests and before delivering or consuming results. A stale source/index is a **stop**, because a lexical fallback over stale evidence is stale too. Rebuild/review a new snapshot and new request identity. Do not silently relabel an old response as belonging to new bytes. Consumers still need to recheck their edit snapshot at application time.

The portable example verifies a manifest's index-artifact hash, full-file hashes and UTF-8 byte slices. It does not parse Woods generations, discover methods, pack an author context, apply edits or run source code. Its `index_generation` is producer-supplied descriptive metadata; the artifact hash is the verified identity.

## Requests and response validation

Build provider state from a positive field allowlist. For evidence selection this can be a task description and candidate identity/path/range/source. Private acceptance tests, expected winners, reference patches, app records, credentials and incidental configuration are not useful selector inputs. They also invalidate a blinded evaluation if disclosed. Comments/source remain data, even when their text resembles instructions.

Batch independent questions using a measured serialized-request cap. The reference uses **24 KiB locally**, 128 candidates and 32 requests; these are sample policies, not asserted service limits. A single oversized card stops so the caller can choose an explicit representation. Do not silently truncate a method and then label it complete. The experiments' representation/packing decisions are separate from this deliberately smaller example.

Validate a successful response before using any ranking: duplicate JSON keys, nonfinite values, booleans masquerading as numbers, unexpected IDs/types/models and invalid usage all matter. Keep question/answer sets exact. The example checks probability bounds before float conversion and accepts only integer usage counters from zero through one billion per counter/request. This local numeric safety bound is not a provider limit; rejected counters remain unknown. It accepts only its explicitly supported Noul/usage schema and normalizes accepted records before saving them.

If any request in a task fails, discard the whole model vector and use the predeclared deterministic ordering. Do not combine scores for completed chunks with unrelated baseline scores for failed chunks. Preserve known usage from successful or otherwise parseable responses; an invalid answer does not make the request free. An unknown usage counter is not zero.

Expected filesystem/schema failures during later source freshness checks stop output and preserve counters already validated. Explicitly validate input containers rather than allowing an attribute error to escape, and handle expected errors at the stage that owns accumulated usage. These checks are separate from recovery after a process crash, which this miniature client does not provide.

The example keeps low probabilities as valid rankings. **Semantic abstention is a separate application decision**, requiring a validated criterion and evaluation on the target workload; neither an HTTP failure nor a Noul near 0.5 establishes that a developer lacks sufficient evidence. See [evidence selection](03-evidence-selection.md) and [pitfalls](08-pitfalls-and-diagnostics.md).

## Replay and cache identity

Bind a reusable result to all inputs that determine its meaning:

- exact serialized request bytes and batch order, including task/state, candidate IDs, instructions and criteria;
- requested model and the returned model version the client expects;
- rubric and composition-policy versions;
- source-file/slice hashes and source coordinates;
- index artifact hash and generation identity;
- any deterministic shortlist/prompt/packing policy whose output is being cached.

The example binds canonical manifest content and exact request hashes to a local capture. Changing a source span, model, rubric, task or generation invalidates replay. Replay never escalates itself into a live request. A stored hash proves that the local bytes still match; it is not provider attestation, source authorization or protection against someone editing both the capture and its metadata.

Validate all replay receipt containers, statuses and response serialization before consuming any recorded response. The example also rejects nonfinite JSON exponent overflow and invalid UTF-8 response serialization at preflight. It rejects receipts following a failed receipt because its writer always stops on the first failure. A terminal failure may end the receipt list before all planned requests were attempted. This keeps malformed later records from creating a misleading partial replay.

Do not share caches merely because two users submitted identical text. A production cache needs tenant/source authorization, retention limits and deletion semantics. A request hash can be sensitive metadata; normalized answers can also reveal private behavior. The example supplies no shared cache or retention service.

An alias such as `jev-latest` can resolve differently later. Record the request name and exact returned identity separately. Reject an unexpected return until the model change is reviewed and evidence recaptured; do not silently broaden the validator to accept any version. The fixture's historical `jev-1.13.0` value is an illustrative explicit pin, not a guarantee that this model remains available.

## Credentials without repeated 1Password calls

Run one long-lived batch process under `op run`, using a reference-only env file:

```dotenv
TYPESAFE_API_KEY=op://VAULT/ITEM/password
```

The [example README](examples/README.md#explicit-live-use) provides the complete command. `op run` resolves references for a child process; that process reads its credential once and reuses it in memory across requests. Avoid launching a fresh credential lookup for each candidate or question. “Once” here means one batch invocation/credential resolution, not a claim about the CLI's internal network-request count. See [1Password's command documentation](https://developer.1password.com/docs/cli/reference/commands/run/).

Keep the secret out of manifest/capture files, source control and command-line arguments. The supplied env file contains only a placeholder reference. The Python client removes the environment entry after reading it and does not launch children; this reduces accidental inheritance but does not promise secure memory erasure or protection from same-user inspection. For a durable service, use the host's scoped secret-injection and rotation mechanism rather than introducing a plaintext local key cache.

## Operational outcomes

| Condition | Response | Record |
|---|---|---|
| Complete valid answers | Apply declared ranking policy | Exact request identity, returned model, raw known usage |
| Transport/status/schema failure | Whole-vector fallback, or caller-declared stop | Failure category; known/unknown usage; attempted requests |
| Source/index/replay drift | Stop and rebuild evidence | Which fixed validation category failed |
| Low scores or ambiguous evidence | Keep separate from service failure | Explicit semantic policy/outcome, if one exists |
| Consumer declines to edit | Count the abstention in the task denominator | Supplied evidence and actual author usage |

Live requests may incur cost; reuse one primary vector across policy/budget comparisons. At the user-supplied estimate of **$0.042 per million input tokens with free output**, compute `known_input_tokens * 0.042 / 1_000_000`. Keep this separate from author input/output/cache usage, local compute and engineering time. Unknown actual subscription/provider billing should remain unknown. Synthetic fixture usage demonstrates this calculation and is not a measurement. See [cost and adoption](07-cost-and-adoption.md).

The reference transport has a fixed certificate-verified HTTPS endpoint, rejects redirects, caps response bytes, uses connection/socket timeouts and checks elapsed body-reading time. It logs sanitized categories rather than server error bodies or credential-bearing exception strings. It has no implicit retry. TypeSafe's documentation describes SDK retries for throttling/overload; using them in an experiment requires counting every attempt and its known usage rather than assuming the SDK made one call.

This small stdlib adapter does not provide a hard deadline across OS DNS resolution and slow response headers, distributed rate limiting, cancellation supervision, resumable journaling, encrypted storage or a production cache. An interrupted live CLI run can lose telemetry; a manual rerun can be billed again. These are explicit adoption tasks, not demonstrated capabilities. Before integrating with Woods, add only the missing operational pieces your deployment needs and preserve the strict identity/validation boundary.

## Readiness

The portable reference has been exercised with its synthetic replay and 28 offline tests, including mocked HTTPS behavior and adversarial input/accounting regressions. Windows drive/stream paths are rejected by lexical checks tested on the current host; no native Windows execution or ACL validation is claimed. **No new live call was made with this adapter.** The separate [trial ledger](06-trial-ledger.md) describes actual provider experiments and their limitations. Copying this example into a service still requires current API verification, a small explicit live contract check, source/privacy review appropriate to that service, and application-level acceptance evidence.
