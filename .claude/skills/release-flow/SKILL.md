---
name: release-flow
description: Prepare the one-off Woods 1.6.4 maintenance release without publishing.
---

# Legacy maintenance release flow

Read `CONTRIBUTING.md#maintenance-release`. This adapter is limited to
`1.6.3 -> 1.6.4.alpha -> 1.6.4`, with task-owned VERSION, changelog and README
maintenance banner. Do not copy v2 surface claims into this tree.

Run `bin/rake "release:reopen[1.6.4.alpha]"` and, after review/commit,
`bin/rake "release:prepare[1.6.4]"` only when authorized. Both require a clean
checkout. Never edit VERSION or release-state fences by hand, and never finish
a refused transition manually. Ordinary release notes go under a classified
Unreleased heading or in `changelog/<type>_<slug>.md`.

After each transition, inspect every generated edit. Run release_legacy specs,
the full suite and lint; validate real Rails credential rotation and installed
package smoke on the floor/latest runtimes. Report version transitions, exact
source/artifact hashes and all validation, including failures and pending tests.
The source/package tests prove a candidate, not that RubyGems published it.

Agents must not tag, push tags, dispatch release workflows, publish gems,
or create GitHub Releases. Those remain maintainer steps. Create the remote
target only after the trusted main policy merges and effective pull-request,
non-force-push, and deletion protections are verified. The candidate branch has no
publishing workflow; trusted main must pin its final reviewed SHA before publication can be allowed. Do not re-enable the
old automatic tag-push publisher or bypass exact CI/artifact identity gates.
