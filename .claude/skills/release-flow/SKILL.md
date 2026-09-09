---
name: release-flow
description: Woods release flow — the version states `main` moves through, the one command per transition, and the line between what an agent may run and what only a maintainer does. Use when asked to cut, prepare, tag, or publish a release, to bump the version, to fold the changelog, or when a release check fails (an alpha tag refused, a stale `release-state` fence, a missing dated changelog heading).
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
| `the Unreleased section is empty; nothing to release` | no entries collected | there is nothing to release |
| `entries sit outside a ### heading in Unreleased` | an entry with no `###` block | file it under a heading |
| `release tag ... is an alpha development marker` | an alpha reached a validator | the release commit was skipped; run `release:prepare` |
| `version-banner does not match the ... state` | a fence was hand-edited | re-run the task for the current VERSION |
| `surface-inventory.json is stale` | a public surface changed | `bin/rake release_v2:write_surface_inventory` |

## Anti-patterns

- Do not "fix" the enforcement spec to match a hand-edited tree. It describes
  the flow; the tree is what is wrong.
- Do not cut a release to make a check pass.
- Do not create a stable branch speculatively. `N-M-stable` exists only when a
  released line needs a patch after a newer major has shipped.
