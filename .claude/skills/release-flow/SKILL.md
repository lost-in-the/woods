---
name: release-flow
description: Woods release flow: the version states `main` moves through, the one command per transition, and the line between what an agent may run and what only a maintainer does. Use when asked to cut, prepare, tag, or publish a release, to bump the version, to fold the changelog, or when a release check fails (an alpha tag refused, a stale `release-state` fence, a missing dated changelog heading).
---

# Release Flow

`main` is the development branch and never claims a released version. Between
releases it carries the alpha development marker. Every release, including a
beta or a release candidate, is an explicit commit plus a tag.

`CONTRIBUTING.md` (the "Release flow" section) is the canonical user-facing
document. This skill is the agent-facing version: the rules, the commands, and
what to report.

## 1. The four states

| State | `Woods::VERSION` | Tagged | On RubyGems | Docs and gemspec URIs point at |
|---|---|---|---|---|
| Development | `X.Y.Z.alpha` | never | never | `main` |
| Beta | `X.Y.Z.betaN` | `vX.Y.Z.betaN` | prerelease | the tag |
| Release candidate | `X.Y.Z.rcN` | `vX.Y.Z.rcN` | prerelease | the tag |
| Release | `X.Y.Z` | `vX.Y.Z` | stable | the tag |

RubyGems treats any letter in a version as a prerelease, so a `~> 1.6` or
`~> 2.0` constraint never resolves a beta or a release candidate. An adopter
takes one explicitly: `gem "woods", "2.0.0.beta1"`.

The state is derived from `Woods::VERSION` alone, by
`Woods::Release::VersionState`. Nothing else records it.

## 2. Rules during ordinary feature work

- **Never edit `lib/woods/version.rb` by hand.** Only `release:prepare` and
  `release:reopen` write it.
- **Changelog entries go under `## [Unreleased]` only**, beneath one of its
  `###` headings. An entry directly under `## [Unreleased]` with no heading
  blocks the next release. Duplicate headings are fine; they merge at release
  time, in the order they first appear.
- **Never hand-edit a `release-state` fence.** The four fences (README version
  banner, both CONTRIBUTING repository-link paragraphs, the upgrade guide's
  availability note) are generated from VERSION by `Woods::Release::Notes`.
- **Never promise an unreleased capability as available** in `plugin/skills/`.
  The distributed plugin has its own version and is not coupled to the gem's.

## 3. One command per transition

Each command refuses a dirty working tree. None of them commits, tags, pushes,
or publishes.

| Transition | Command |
|---|---|
| Alpha to the first beta | `bin/rake "release:prepare[2.0.0.beta1]"` |
| Beta to the next beta or a release candidate | `bin/rake "release:prepare[2.0.0.rc1]"` |
| Release candidate to the release | `bin/rake "release:prepare[2.0.0]"` |
| After the release publishes, reopen development | `bin/rake "release:reopen[2.1.0.alpha]"` |

`release:prepare` bumps VERSION, folds `## [Unreleased]` into
`## [<version>] - <date>` with one block per `###` heading, leaves an empty
Unreleased behind, restates the fences, regenerates the surface inventory, and
prints the tag and dispatch commands. `release:reopen` sets the next alpha and
restores the alpha documentation state; it leaves the changelog alone.

Every rewrite is computed before any of it is written, so a refusal leaves the
working tree untouched. Never "finish" a refused prepare by hand.

`release:prepare` also runs `release:preflight` and prints its report before
the tag and dispatch commands: three advisory, no-write checks for the live
prerequisites a dispatch cannot verify until it is already running (the
`release` environment's protection rule and admin-bypass setting, via `gh
api`; whether `REQUIRED_CI_JOBS` in `script/validate-release-run` still
matches `ci.yml`'s job names; whether both `download-artifact` steps in
`release.yml` set `merge-multiple: true`). A `WARNING` does not block
`prepare`; a missing or failing `gh` shows `SKIPPED` rather than failing it.
Run it alone with `bin/rake release:preflight`.

A **final** release also absorbs every prerelease section of its own base
version: cutting `2.0.0` folds `## [2.0.0.beta1]` and `## [2.0.0.rc1]` into
`## [2.0.0] - <date>` and removes their headings, prerelease entries first and
anything written after them second. So an empty `## [Unreleased]` is legitimate
for a final release cut straight from a release candidate, and is a refusal for
a beta or a release candidate, which has nothing to absorb.

It refuses a version that moves backwards, a version whose base is not the line
`main` is developing (`2.0.0.alpha` releases only `2.0.0`), an alpha target for
`prepare`, and a non-alpha target for `reopen`.

## 4. What an agent may and may not do

**May**: run either task when asked; review and report the diff; run the
checks below; write the commit and pull request; quote the tag and dispatch
commands the task printed.

**May not**: edit VERSION or a fence by hand; create, move, or push a tag; run
`gem push`, `rake release`, or `rake release:rubygem_push` (the last two are
blocked and abort); trigger the `repository_dispatch` release workflow. Tagging
and dispatch are maintainer steps, always.

## 5. Checks to run after a transition

```bash
bin/rspec spec/release_v2
bin/rake release_v2:verify_surface_inventory
bin/rspec spec/integration/packaged_gem_spec.rb
bin/rspec
bin/rubocop
```

`spec/release_v2/version_state_spec.rb` is the enforcement: on any commit,
VERSION is either an alpha or the changelog carries its dated heading, every
fence matches the state, no unregistered fence exists, and the plugin version
stays independent.

## 6. What to report

- the transition, from and to;
- the files the task changed;
- the changelog headings folded into the release section;
- the check results;
- the exact tag and dispatch commands, quoted from the task output, marked as
  maintainer steps.

## 7. Diagnosing a failure

| Symptom | Cause | Fix |
|---|---|---|
| `release:prepare refused: the working tree has uncommitted changes` | uncommitted work | commit or discard first |
| `does not come after the current version` | target moves backwards | pick a later version |
| `main is developing X.Y.Z` | target base does not match the alpha | release the base `main` is on, or reopen at a new base first |
| `the Unreleased section is empty; nothing to release` | a beta or rc with no entries since the last one | there is nothing new to publish |
| `the Unreleased section is empty and no X.Y.Z prerelease section exists` | a final release with nothing to ship | there is nothing to release |
| `entries sit outside a ### heading in Unreleased` | an entry with no `###` block | file it under a heading |
| `release tag ... is an alpha development marker` | an alpha reached a validator | the release commit was skipped; run `release:prepare` |
| `version-banner does not match the ... state` | a fence was hand-edited | re-run the task for the current VERSION |
| `surface-inventory.json is stale` | a public surface changed | `bin/rake release_v2:write_surface_inventory` |

## 8. When a dispatch fails

`release-context` and `publish` read `github.sha` (main's tip at dispatch
time) for the validators, `script/verify-release-tag`, the workflow files, and
the live `release` environment. Only `package-test` reads `release-sha` (the
tag's own commit), because that is the code CI actually tested; `publish`
pushes the artifact CI built at that commit without rebuilding it.

| What failed | Fix |
|---|---|
| `script/validate-release-run`, `script/validate-release`, `script/verify-release-tag`, `ci.yml`, `release.yml` | merge to main, re-dispatch at the same tag; the tag does not move |
| The live `release` environment (protection rule, admin bypass) | fix the setting directly; no re-dispatch needed |
| `CI run <id> tested ref is main, expected v<version>` | the dispatch named main's CI run; re-dispatch with the run the tag push started (its branch column reads the tag), nothing to merge |
| `spec/` or `lib/` that `package-test` runs against the candidate | merge the fix, then the maintainer moves the tag to the new main tip, waits for a fresh CI run, and re-dispatches |

**Moving a tag is a maintainer step, and only before `publish` has pushed the
gem.** After publication the tag is permanent. Report which class a failure
belongs to; do not guess at a tag move yourself.

## 9. Publishing the GitHub Release entry

The workflow creates no GitHub Release (`.github/workflows/release.yml` has
no such step, and `spec/release_v2/release_workflow_spec.rb` asserts none
exists), because the API cannot atomically bind an existing tag to an
expected commit. Once RubyGems shows the version published, the maintainer
runs:

```bash
gh release create v<version> --verify-tag --notes-file <file>              # final release
gh release create v<version> --verify-tag --prerelease --notes-file <file> # beta or rc
```

`<file>` links `CHANGELOG.md` at the tag (never at `main`) and anchors to
that version's dated heading. Agents may draft `<file>`'s contents; running
`gh release create` and choosing when to run it are maintainer steps.

## Anti-patterns

- Do not "fix" the enforcement spec to match a hand-edited tree. It describes
  the flow; the tree is what is wrong.
- Do not cut a release to make a check pass.
- Do not create a stable branch speculatively. `N-M-stable` exists only when a
  released line needs a patch after a newer major has shipped.
