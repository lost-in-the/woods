# Compatibility

Woods follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html), and this page defines its public API.
Check a change against it before you release it.
Which release lines receive fixes is in [SECURITY.md](../SECURITY.md#supported-versions).

## Who depends on what

| Who | Surfaces | Rule |
|---|---|---|
| People who configure and run Woods | Configuration, environment variables, rake tasks, executables, generators | Strict |
| Programs that read the index | Index files, `Woods::PublishedIndex` | Strict envelope, notice for the rest |
| Agents that call MCP tools | Tool names and parameters, tool output | Strict names and parameters, loose output |

Configuration lives in initializers, CI jobs and hooks, where a change breaks a pipeline nobody watches.
Programs such as Woods Map parse index fields with fixed code, so they need a note when a field changes.
An agent rereads tool descriptions and output on every call, so new fields or wording cost it nothing.
Tool names and parameters are written into client configuration, skills and prompts, so they stay strict.

## Stable within a major release

A minor or patch release may add to these.
It never removes or renames one, narrows what it accepts, or makes an optional input required.
A valid invocation keeps working, except under the refusal rule below.

| Surface | Defined in |
|---|---|
| Configuration keys, accepted values, presets | [Configuration reference](CONFIGURATION_REFERENCE.md); `configuration_attributes`, `presets` in `.Codex/release-v2/surface-inventory.json` |
| Environment variables | The tables in the [configuration reference](CONFIGURATION_REFERENCE.md) |
| Rake task names and arguments | `lib/tasks/woods.rake`, `woods_checks.rake`, `woods_evaluation.rake`; `rake_tasks` in the inventory |
| Executables, flags, arguments | `exe/`, `spec.executables` in `woods.gemspec`; `executables` in the inventory |
| Rails generators and options | `lib/generators/woods/` |
| MCP tool and resource names, parameters, required parameters, accepted values | `lib/woods/mcp/server.rb` and the tool files beside it; `lib/woods/console/`; `index_mcp`, `console_mcp` in the inventory |
| Ruby entry points | `public_woods_methods` in the inventory (`Woods.configure`, `Woods.extract!` and the rest); [`Woods::PublishedIndex`](PUBLISHED_INDEX.md) |
| Index envelope | [Index readers](#index-readers) |
| Lowest supported Ruby and Rails | `required_ruby_version` and `railties` in `woods.gemspec` |

Maintainer tasks (`release:*`, `woods:self_*`) are not covered.

## May change in a minor release

| Change | Notice |
|---|---|
| Add a field, unit type, edge kind, artifact, tool, parameter or output field | Changelog entry |
| Correct a wrong value, such as a dangling edge or a misclassified unit | Changelog entry; upgrade note if a program could match the old value |
| Change tool output text, order or rendering | Changelog entry |
| Change the type or meaning of a documented index or structured output field | Upgrade note |
| Remove such a field | Upgrade note, one minor release after its deprecation |
| Return less by default, such as a new page size or cap | Upgrade note |
| Change a default | Upgrade note naming the setting that restores it |
| Refuse input that would give a wrong, partial or unsafe result | Upgrade note naming the remedy and any opt-out |
| Change a documented Ruby class outside the entry points, such as `Woods::MCP::Server.build` | Upgrade note |

For example, `woods-mcp-start` refuses an index another checkout recorded, since its answers describe other code.
Its message names the remedy, and `--allow-mismatch` or `WOODS_MCP_ALLOW_MISMATCH=1` overrides it.

An upgrade note is a `changelog/upgrade-notes_<slug>.md` entry that says who is affected and what to do.
Not a contract: human-readable fields such as `frequency_human_readable` and `SUMMARY.md`, and tool descriptions.
Nor are log lines, listing order, temporary names, or Ruby constants this page does not name.

A patch release fixes defects.
It changes no default, adds no refusal and needs no upgrade note, unless it fixes a security issue.

## Upgrading an index

- **A newer reader serves an older index of the same major.**
  It does not translate old fields: a field an older index lacks means unknown, not empty or false.
- A read that an older payload cannot satisfy answers `index_build_mismatch` and names the writing build.
  It asks for `woods:extract`, and the rest of the index keeps serving.
- **A writer may refuse an older baseline.**
  `woods:incremental`, `woods:refresh` and the watch daemon refuse an index they cannot extend, and say why.
- **The remedy is at most one full `woods:extract`.**
  The previous generation stays published until it finishes.
- `woods.json` and the embedding dumps are versioned files.
  A minor release reads the versions that earlier releases of the same major wrote.
- An older Woods reading a newer index is not supported.
  A Woods 1.x index needs the [2.0 upgrade](UPGRADING_TO_2.md).

## Index readers

The envelope is stable within a major:

- the `generation.json` fields, and how they resolve the payload directory;
- where `manifest.json`, `dependency_graph.json` and each type's `_index.json` live;
- each unit's `identifier` and `type`, and the fields in the
  [field reference](EXTRACTOR_REFERENCE.md#extractedunit-field-reference);
- the top-level keys of `dependency_graph.json`;
- the version fields of versioned artifacts, such as `schema_version` in `git_commits.json`.

A unit's `metadata`, its edge kinds, which edges exist and which type a unit has may change in a minor release.
Ignore fields you do not know, and read each unit's type from the unit, not from its directory.
`woods_version` and `woods_revision` in `manifest.json` name the build that wrote the index.
[Published index layout](INDEX_LAYOUT.md) describes every file.

## Deprecation

- A deprecation is announced in a minor release, with a changelog entry, a warning the first time it is used
  in a process, a notice in its documentation, and a named replacement or a statement that there is none.
- It keeps working without change until it is removed.
- A stable surface is removed no earlier than the next major release, and the warning names it: "removed in Woods 3.0".
- A documented index or structured output field can be removed in a later minor release,
  at least one minor release after its deprecation.
- A renamed input keeps its old name working: `WOODS_OBSIDIAN_*` is still read when `WOODS_MARKDOWN_*` is unset.

| Deprecated | Since | Use instead | Removed in |
|---|---|---|---|
| `config.similarity_threshold` | 2.0 | Nothing: it is inert | 3.0 at the earliest |
| `config.extractors` | 2.2 | Nothing: every extractor always runs | 3.0 |
| `woods:notion_sync`, `woods:send`, the `notion_sync` tool, `notion_*` configuration | 2.2 | `woods:markdown` | 3.0 |
| `woods:unblocked_sync`, `woods:relay` | 2.2 | `woods:markdown` | 3.0 |
| `woods:obsidian`, `woods:vault` | 2.2 | `woods:markdown` with `WOODS_MARKDOWN_OBSIDIAN=1` | 3.0 |
| Console MCP server: `woods-console-mcp`, `woods-console`, `woods:console` | 2.2 | See [#1098](https://github.com/lost-in-the/woods/issues/1098) | 3.0 |
| State machine `metadata.callbacks` | 2.2 | `metadata.transition_callbacks` | 2.3 at the earliest |
