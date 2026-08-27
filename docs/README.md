# Woods documentation

Woods extracts runtime-accurate Rails context and serves it to coding agents through MCP. Start with the task you are trying to complete; you do not need to read the documentation in order.

## What are you trying to do?

| Task | Start here | You will finish with |
|---|---|---|
| Install Woods in a Rails app | [Getting started](GETTING_STARTED.md) | A validated codebase index with the 14 packaged-default tools connected |
| Ask an agent to install or configure Woods | [Agent setup runbook](AGENT_SETUP.md) | A safe, reviewable install with an agent handoff report |
| Configure an MCP client or Docker path | [MCP servers](MCP_SERVERS.md) | A working Index Server and, if authorized, an optional Console Server |
| Use Woods tools as an agent | [Agent guide](AGENT_GUIDE.md) | A repeatable query workflow for code context, flows, and blast radius |
| Keep the index current automatically | [Watch daemon](WATCH_DAEMON.md) | A resident development process that catches up changes and republishes the index |
| Upgrade from Woods 1.x | [Upgrade to Woods 2.0](UPGRADING_TO_2.md) | A backed-up, re-indexed, verified v2 installation |
| Diagnose an error | [Troubleshooting](TROUBLESHOOTING.md) | Symptom-to-cause checks for extraction, MCP, embeddings, storage, and Docker |
| Contribute to Woods | [Contributing](../CONTRIBUTING.md) | A tested change with synchronized docs and plugin guidance |

## First-time setup

- [Getting started](GETTING_STARTED.md): install, generate configuration, migrate, extract, validate, and connect the Index Server.
- [Agent setup runbook](AGENT_SETUP.md): the same result with version checks, repository safety, approval boundaries, and a copyable agent prompt.
- [Docker setup](DOCKER_SETUP.md): extraction inside the container, container-first MCP launch, optional host launch, and path translation.
- [Configuration reference](CONFIGURATION_REFERENCE.md): every supported option, default, and environment variable.
- [Backend matrix](BACKEND_MATRIX.md): choose structural-only, local Ollama, pgvector/OpenAI, Qdrant/OpenAI, or shared-filesystem deployment.

## MCP and agents

- [MCP servers](MCP_SERVERS.md): choose the pre-extracted Index Server or live-data Console Server; configure clients; understand the callable 14 and 9/11 tool surfaces.
- [Agent guide](AGENT_GUIDE.md): start with `woods_status`, discover with `search`, inspect with `lookup`, and follow dependencies or flows.
- [MCP tool cookbook](MCP_TOOL_COOKBOOK.md): scenario-based calls with parameters and expected response shapes.
- [Console MCP setup](CONSOLE_MCP_SETUP.md): Console transports, blocked tables, credential scanning, redaction, SQL validation, and production safeguards.
- [MCP HTTP transport](MCP_HTTP_TRANSPORT.md): shared/remote Index Server transport, authentication, origins, and protocol details.
- [MCP worktree setup](MCP_WORKTREE_SETUP.md): register Woods correctly when agents work in linked git worktrees.

## Index lifecycle

- [Incremental extraction](INCREMENTAL_EXTRACTION.md): update changed paths while preserving full-extraction equivalence.
- [Watch daemon](WATCH_DAEMON.md): keep an index current with a resident process.
- [Retrieval guide](RETRIEVAL_GUIDE.md): configure embeddings and understand semantic retrieval, ranking, and token budgets.
- [Embedding models](EMBEDDING_MODELS.md): choose and size local Ollama models.
- [Upgrade to Woods 2.0](UPGRADING_TO_2.md): identifier changes, atomic payloads, durable-store reconciliation, and rollback.

## Reference

- [Why Woods](WHY_WOODS.md): the problems runtime introspection solves.
- [Architecture](ARCHITECTURE.md): extraction, publication, graph, storage, retrieval, and MCP components.
- [Extractor reference](EXTRACTOR_REFERENCE.md): what each extractor produces and the edge cases it handles.
- [Backend matrix](BACKEND_MATRIX.md): implemented provider/store combinations and their operational requirements.
- [Token benchmark](TOKEN_BENCHMARK.md): evidence behind Woods token-estimation defaults.
- [FAQ](FAQ.md): short answers and links to the canonical guides.

## Exports and integrations

- [Notion integration](NOTION_INTEGRATION.md)
- [Obsidian integration](OBSIDIAN_INTEGRATION.md)
- [Unblocked integration](UNBLOCKED_INTEGRATION.md)

## Maintainer material

Historical build-phase documents are not user guides. Source checkouts also contain the [MCP protocol decision record](https://github.com/lost-in-the/woods/blob/main/docs/design/MCP_2026_STRATEGY.md), [generated self-analysis diagrams](https://github.com/lost-in-the/woods/tree/main/docs/self-analysis), and the maintainer work ledger in `backlog.json`; these maintainer-only paths are not packaged with the gem.

## Canonical owners

Use this map when changing behavior or documentation. Update the owner first; other pages should summarize and link instead of copying full instructions.

| Fact or workflow | Canonical owner |
|---|---|
| Install and first successful run | [GETTING_STARTED.md](GETTING_STARTED.md) |
| Agent-operated install/configuration | [AGENT_SETUP.md](AGENT_SETUP.md) |
| Configuration keys and defaults | [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) |
| MCP server setup and callable tool surface | [MCP_SERVERS.md](MCP_SERVERS.md) |
| Agent tool-selection workflow | [AGENT_GUIDE.md](AGENT_GUIDE.md) |
| Console security and transports | [CONSOLE_MCP_SETUP.md](CONSOLE_MCP_SETUP.md) |
| v1-to-v2 migration | [UPGRADING_TO_2.md](UPGRADING_TO_2.md) |
| Failure diagnosis | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Contributor policy | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Coding-agent repository instructions | [AGENTS.md](../AGENTS.md) |

The current public surface is generated from 34 extractors. Counts and capability claims must match `.Codex/release-v2/surface-inventory.json`, which is generated from the code and verified in CI.
