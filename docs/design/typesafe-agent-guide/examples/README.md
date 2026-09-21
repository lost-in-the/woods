# Portable evidence-ranking reference

This Python 3.10+ standard-library example turns exact source spans into independent Noul usefulness judgments, then ranks the supplied candidates. It is a small adapter reference, not a Woods plugin or a reproduction of the research harness.

**Default execution is offline.** The tiny catalog/retry files, index marker, probabilities and usage counts under `fixture/` are synthetic, hand-written illustration. They provide no evidence of model quality, provider latency or actual billing. The ranker reads those source files as bytes; it never imports or executes them.

From the Woods repository root:

```bash
python3 docs/design/typesafe-agent-guide/examples/rank_evidence.py
python3 -m unittest discover -s docs/design/typesafe-agent-guide/examples -p 'test_*.py' -v
```

After copying this whole `examples/` directory elsewhere, run from that directory:

```bash
python3 rank_evidence.py
python3 -m unittest discover -s . -p 'test_*.py' -v
```

The default replay ranks `C001`, `C002`, `C003`, labels usage `synthetic_replay`, and estimates `$0.0000252` from its invented 600 input tokens. This number is a formula demonstration, not a measured charge. All 28 tests pass offline. Mocked HTTP tests exercise transport branches; the reference live adapter has **not** been called against TypeSafe as part of preparing this guide.

## Files and inputs

- `rank_evidence.py`: source verification, request construction, batching, strict response validation, ranking/fallback, replay and optional HTTPS transport.
- `test_rank_evidence.py`: malformed-response, source freshness, cross-file/offset, UTF-8, request identity, fallback, cost, credential-read and mocked-transport checks.
- `fixture/manifest.json`: task, explicit request/expected-returned models, rubric/index identity and candidate byte coordinates/hashes.
- `fixture/replay.json`: clearly labeled fake capture bound to the exact illustrative requests.
- `typesafe.env.example`: only a 1Password reference; it contains no credential.

To adapt the fixture, generate a manifest from an immutable source/index snapshot. Each candidate needs a stable `Cnnn` ID, identifier, relative file path, start/end **UTF-8 byte offsets**, a SHA-256 of the whole file, and a SHA-256 of the exact slice. The paths resolve relative to the manifest's directory. The `index_file` is a local snapshot identity artifact whose bytes must match `index_sha256`; `index_generation` is the producer's descriptive generation label. The example verifies the bytes but does not interpret Woods' publication layout or extract methods itself.

Paths use relative forward-slash components. Absolute paths, traversal, symlinks, backslashes and colons are rejected; rejecting colons also excludes Windows drive-qualified and alternate-data-stream paths. The suite checks Windows path semantics lexically on the test host; it does not establish native Windows runtime or filesystem-permission behavior.

Never repair coordinates or update hashes after a freshness failure merely to reuse an old capture. Rebuild the snapshot/manifest and explicitly produce new evidence. Source and index hashes are checked initially, before each request and again before ranking is returned. A changed manifest also stops output. These checks are not a filesystem sandbox or protection against a malicious process racing directory operations.

## Contract and limits

The provider gets only the task string and allowlisted candidate identity, path, byte range and source. Question instructions reference the candidate in state because question-map IDs are response keys, not inference instructions. Private labels, reference implementations, tests, credentials and arbitrary extra card fields are not transmitted.

Requests use compact, sorted JSON. **24 KiB is this example's local serialized-request cap, not a claimed TypeSafe API maximum.** Oversized individual candidates stop; the example does not silently clip source. Local caps are 128 candidates and 32 requests. These are operational guardrails, not recommended production settings or measured provider limits.

Responses must have the configured returned model, exactly the requested answer IDs, Noul types, finite non-boolean probabilities in `[0,1]`, and exactly the two integer usage counters documented by this adapter. Each counter must be in `[0, 1_000_000_000]` per request; this generous local safety bound prevents unsafe numeric conversions and is not a claimed provider limit. Out-of-policy counters remain unknown. Probability bounds are checked before float conversion so even enormous JSON integers fail safely. Duplicate JSON keys and nonfinite literals are rejected. Extra top-level/answer text is discarded before capture. A future usage-schema expansion will require an explicit adapter change.

A failed request or invalid answer discards the **whole** model vector and uses deterministic token-overlap ordering with candidate-ID ties. This illustrative fallback is simpler than the BM25 baseline used in the experiments. It stops further requests after the first failure and never retries implicitly. All valid low scores still produce a ranking; this is not an abstention policy or evidence-completeness test.

| Result | Meaning | Exit |
|---|---|---:|
| `ranked` | Complete validated vector, sorted by Noul value then ID | 0 |
| `no_candidates` | Empty candidate set; no ranking evidence | 0 |
| `fallback` | Request/response failure; entire vector replaced by deterministic ordering | 1 |
| `stopped` | Stale or invalid source/index/manifest, replay mismatch, missing credential or local limit | 2 |

Raw known usage is retained even if answer/model validation fails. Missing/malformed usage stays unknown; `estimated_known_input_cost_usd` is only the known input subtotal. `usage_complete` concerns attempted requests, not hypothetical unmade requests. Stale-source stops and expected filesystem/schema errors during a later freshness check retain previously known counters but return no ranking. Capture/request persistence is optional; this small CLI does not journal in-flight attempts, so an interrupted process can lose telemetry and a manual rerun can incur another charge. Do not automate such reruns as though they were free retries.

## Explicit live use

Read the current [TypeSafe HTTP API](https://docs.typesafe.ai/api) before choosing models. The fixture's `jev-1.13.0` ID records the model used in the experiments; its continued availability is not guaranteed. Update both model fields in your manifest to the request name and the exact returned model you intend to accept. An alias and a resolved version may differ. Both explicit CLI model flags must match the manifest.

From this directory, after configuring the reference-only env file:

```bash
op run --env-file typesafe.env.example -- \
  python3 rank_evidence.py --manifest fixture/manifest.json \
  --live --request-model jev-1.13.0 --expected-model jev-1.13.0 \
  --save-capture live-capture.json
```

This sends the supplied source to TypeSafe and can incur usage. `op run` resolves `op://VAULT/ITEM/password` once for the process. The Python client reads and removes `TYPESAFE_API_KEY` from its environment once, holds it in memory and reuses it for the batch. It does not invoke `op`, put the key in arguments, or write it into captures. This is not a claim of secure memory erasure or protection from same-user process inspection. See [1Password's `op run` documentation](https://developer.1password.com/docs/cli/reference/commands/run/).

The transport uses only `POST https://api.typesafe.ai/v1/systemone`, default certificate verification, no proxy autodetection, no redirects, no retries, a 5-second connection timeout, 15-second socket operations, a checked 45-second body-reading deadline and a 1 MiB response cap. Error bodies and exception strings are not logged. DNS resolution and slow response-header handling are governed by OS/standard-library behavior; this is **not a hard end-to-end deadline**. A production client needs a process/request supervisor if that guarantee matters, plus operational rate limiting, cancellation, durable telemetry and deliberate retry accounting.

`--save-capture` creates a new file with mode `0600` (owner read/write on POSIX) and refuses to overwrite an existing path. Windows ACLs require the host's access policy. Captures contain validated normalized answers and usage, or sanitized failure categories, bound to exact request hashes and provenance. They contain no key and no copied request source, but retain metadata/probabilities that may still be private. File permissions are not encryption; storage, access and retention remain the host application's responsibility.

For explicit replay of a new capture, keep the corresponding manifest and snapshot unchanged:

```bash
python3 rank_evidence.py --manifest fixture/manifest.json --capture live-capture.json
```

The replay identity covers canonical manifest content, source hashes/spans, task, index hash/generation, rubric version, exact request bytes/order, requested model and expected returned model. Mismatches stop; they do not cause a live request. This is a local replay binding, not provider attestation or an automatic shared cache.

Manifest/capture containers are checked explicitly. JSON parsing rejects nonfinite values from exponent overflow as well as explicit nonfinite literals. Replay checks every receipt's object shape, status, request identity, required response container and response JSON/UTF-8 serialization before consuming any recorded response. A failed receipt must be terminal; an early terminal failure may account for fewer receipts than planned requests because evaluation stops on its first failure. Malformed later receipts or impossible post-failure receipts stop upfront.

Read [architecture and operations](../02-architecture-and-operations.md) for the application boundary, [evidence selection](../03-evidence-selection.md) for retrieval/packing, and [code authoring and evaluation](../04-code-authoring-and-evaluation.md) before connecting rankings to a coding agent.
