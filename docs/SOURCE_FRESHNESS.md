# Source freshness

`woods_status.index.source_freshness` compares the served generation's captured
application inputs with source bytes visible to the reader. It is separate from
index age, HEAD equality, daemon liveness and external database/runtime state.

This capability is unreleased after `2.0.0.beta2`. Check the installed gem's
`woods-extract --help`, `rake -T woods:source_status`, and `woods_status` schema
before using it; upgrading the plugin alone does not upgrade Woods.

## Read the result

| State | Meaning | Next step |
|---|---|---|
| `current` | All covered inputs match their consumer baselines, with a verified fresh boot boundary and complete checks. A dirty checkout can be current. | Use the indexed facts within the coverage below. |
| `drifted` | At least one captured input differs, was removed, or a relevant input was added. | Inspect the changed paths; choose a full run or a justified targeted refresh. |
| `unknown` | Evidence is incomplete: for example an old index, missing source/key, scan limit, opaque symlink directory, or unproved boot/consumer boundary. | Inspect `reasons`; use a deep check or fresh full capture as appropriate. |

Drift can coexist with incomplete coverage. `reasons` reports both; absence of a
listed change never proves an omitted input is unchanged. `complete` describes
capture/traversal completion, while boot and consumer qualifications remain in
`reasons`. `counts` contains total observed added/changed/removed paths; each
`changes` list contains at most 30 paths and `truncated` marks longer lists.

```json
{"source_check":"deep"}
```

Pass this to `woods_status` for an explicit five-second content scan. The default
`quick` scan has a 250ms budget. Both read and HMAC source bytes; there is no
stat-only `current` shortcut, so same-size/same-mtime edits are detected. Limits
also cap traversal at 50,000 visited files and 128 MiB read. Budgets are checked
between filesystem operations; an operating-system read that itself stalls can
outlast the scan deadline. A limit produces unknown coverage, never current.

The result is tied to the **served** generation, including a reader holding an
older generation during a concurrent publication. It is recomputed on each call;
a source edit does not require an index generation change to become visible.

## Establish a fresh baseline

Run the launcher through the application's installed bundle:

```bash
bundle exec woods-extract full
bundle exec woods-extract incremental app/services/checkout.rb app/views/orders/show.html.erb
bundle exec woods-extract refresh routes controllers
```

`--root PATH` selects the application root. `--output PATH` selects the index
(default `WOODS_OUTPUT`, otherwise `tmp/woods`); relative output paths resolve
under the application root. Repeat `--source-root PATH` to include additional
application-relative directories used by custom loaders. Use the same declaration
on subsequent launcher runs. Paths are separate arguments, preserving spaces,
commas and newlines. Refresh accepts known extractor names. Invalid arguments
fail before extraction; the launcher propagates the child's failure or daemon
stand-down exit 75. Split oversized incremental batches or choose full.

The launcher captures source before a **fresh child** evaluates its Gemfile,
Rakefile, Rails boot and eager loading. A private one-use handoff binds the capture
to root, output, action, rules, nonce and parent process. It waits for the child
and removes the handoff when the child exits. Source is checked again before
publication; edits during boot/extraction retain the earlier identity and are
reported, rather than being silently adopted as a current baseline.

Existing Rake tasks, direct `Extractor` calls and the watch daemon remain usable.
Their post-boot capture is marked `unverified_boot_boundary`; current bytes alone
cannot prove what a previously booted Rails process consumed. A fresh launcher
full run replaces that uncertainty. Hooks continue their existing refresh flow;
enabling hooks does not implicitly restart or replace a daemon.

## Scope and partial extraction

Coverage follows the shared file/whole-app dispatch rules and reload policy:
application and lib Ruby, known views/locales/tests/packages/schedules/schema and
boot configuration. Source-only boot coverage also includes `Rakefile`,
`config.ru`, root gemspecs and otherwise-unclassified Ruby helpers under `config/`.
Normal generated/hidden directories are pruned before traversal, using the watch
scanner's exclusions. Explicit source roots override generic exclusions; the
index output is always excluded. Contained file symlinks are checked for stable
resolution; directory symlinks and escaping/unreadable inputs leave uncertainty.

Every consuming scope keeps its own identities. An events scan can reread a
service file while its service unit remains untouched; refreshing events does
not certify the retained service unit. Successful file/whole-extractor work
updates only its scopes, including negative results and confirmed deletion.
Unchanged scopes keep their earlier baseline. Boot inputs advance only on a full
run. Partial runtime changes retain an explicit `runtime_consumption` uncertainty
when Woods cannot prove every retained reflected fact was re-serialized. Named
framework refreshes do not certify unrelated application inputs. A handled
extractor error retains an explicit `extractor:<name>` uncertainty even if the
extractor returns an empty result. Successful consumers keep their own evidence;
a later full run without that failure can replace the uncertainty.

Custom loader source outside captured roots, missing eager-load coverage and
uncaptured application-owned unit paths remain unknown. This is application
source evidence: it does not certify external database schemas/data, remote
configuration, installed gem bytes, provider state or live runtime services.

## Containers and hooks

Run the launcher inside the application container when that is where the bundle
and source exist, for example `docker compose exec -T app bundle exec woods-extract full`.
An MCP reader must see the source and original private key; otherwise it reports
unknown. `woods:source_status` has no Rails environment prerequisite and uses the
same verifier without Rails initialization or provider work. Its optional
Base64-encoded JSON transport supports `output`, `root` (an explicit reader-side
source mapping), and `mode` (`quick` or `deep`).

The opt-in SessionStart hook uses `WOODS_HOOK_RAKE` and `WOODS_OUTPUT`, including a
Docker command prefix without requiring a host application bundle. It prints
an actionable drift or unknown warning and stays quiet for current evidence.
Its ten-second process deadline includes command startup; the scan uses quick
mode. Missing older tasks and failed/timed-out commands report unknown. Cancelling
Docker exec does not itself prove the process inside the container stopped.
A quiet session hook does not acknowledge deferred PostToolUse queue entries.

## Artifact and cost

Each atomic payload contains versioned `source_inputs.json`. It records a compact
identity table shared by per-consumer scope/path maps, root, rules fingerprint,
generation, coverage and scan metrics. All file identities use HMAC-SHA256 with
`<output>/.source-inputs.key`, a 32-byte, owner-only private file outside payloads.
Low-entropy secret-bearing input files receive the same protection as ordinary
source; no source bytes or raw secret hashes are added to this artifact. Do not
publish the key with an index. Missing, insecure or mismatched keys produce
unknown; Woods does not silently repair permissions or rotate keys. Independent
outputs have different identities and must be compared using their own keys and
consumer semantics, not raw manifest equality.

Failed/no-op extraction does not advance the artifact's published generation.
Flat fallback and older indexes lack verified atomic source evidence.
`WOODS_PROFILE=1` reports `source capture` and `source verification` separately.
Capture/recheck each allow up to ten seconds with the same file/byte caps.

September 2026 fixture measurements: a pinned Writebook source tree (456 visited
files, 223 hashed, 233KB) completed quick scans in median 36ms native / 45ms on a
Linux container bind mount. Discourse (26,133 visited, 6,209 hashed, 56.4MB) needed
about 1.6–2 seconds; quick scans returned unknown, while five-second scans completed
traversal and still reported an opaque directory symlink. Native Ruby 4.0 and
container Ruby 3.4 differed, so these are a budget envelope, not a filesystem
speed comparison or a macOS virtiofs benchmark. Measure your own application;
a large or slow source tree may need a full extraction rather than a longer read.
