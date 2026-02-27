# Claude Toolkit Design for CodebaseIndex

## Problem

Every Claude Code session starts from zero on operational knowledge that never changes. This causes:

1. **Context loading overhead** — Re-explaining architecture, conventions, and design decisions each session.
2. **Repetitive workflows** — Same multi-step sequences (pick backlog item, TDD, validate in host app) done manually.
3. **Quality drift** — Changes that don't align with design docs, conventions breaking, test apps getting out of sync.
4. **Retraining cost** — Walking Claude through the two-app testing setup (host app + Docker app) every time.

## Solution

A layered system of rules, skills, and agents that encode operational knowledge, automate workflows, and provide autonomous specialists for common tasks.

## Architecture

### Layer 1: Rules (always-loaded context)

Rules are path-triggered and load automatically when touching relevant files.

| Rule | Trigger paths | Purpose |
|---|---|---|
| `extractors.md` | `lib/codebase_index/extractors/**/*.rb` | Extractor interface conventions |
| `docs.md` | `docs/**/*.md` | Documentation conventions (dual-DB, tables, cross-refs) |
| `storage-retrieval.md` | `lib/codebase_index/storage/**/*.rb`, `retrieval/**/*.rb`, `embedding/**/*.rb` | Storage/retrieval layer conventions |
| `integration-testing.md` | `lib/codebase_index/extractors/**/*.rb`, `spec/**/*_spec.rb` | Host app validation workflow (local + Docker) |

### Layer 2: Skills (reusable instruction sets)

Skills shape behavior when invoked. They don't execute autonomously — they provide the playbook.

| Skill | Purpose |
|---|---|
| `backlog-workflow` | How to pick items from OPTIMIZATION_BACKLOG.md, implement with TDD, mark resolved, add new items |
| `doc-sync` | What docs to check after implementation changes, rules for updating them |
| `mcp-patterns` | MCP server design rules, reference implementation patterns, how to add tools and build new servers |

### Layer 3: Agents (autonomous specialists)

Agents are dispatched with a plan and operate independently. They report results but don't make decisions.

| Agent | Tools | Purpose |
|---|---|---|
| `host-app-validator` | Bash, Read, Glob, Grep | Validates extraction in a host Rails app (local or Docker). Takes environment as parameter. |
| `code-optimizer` | Read, Glob, Grep, Bash | Analyzes code for simplification opportunities. Proposes changes with rationale, doesn't implement. |
| `doc-reviewer` | Read, Glob, Grep | Cross-references recent changes against docs. Reports gaps, doesn't fix them. |
| `use-case-explorer` | Read, Glob, Grep, WebSearch | Identifies extraction coverage gaps and untapped uses for extracted data. Two modes: coverage gaps + untapped uses. |
| `retrieval-designer` | Read, Glob, Grep | Designs retrieval query patterns grounded in RETRIEVAL_ARCHITECTURE.md. Outputs task type, query classification, retrieval steps, token budget allocation. |

### CLAUDE.md Changes

Added to CLAUDE.md (139 lines total):
- **Testing Workflow** — TDD approach by task type (new features, bug fixes, refactors)
- **Backlog Workflow** — Reference to skill
- **Session Continuity** — Breadcrumbs in `.claude/context/session-state.md`

### Privacy

Files with direct references to local projects are gitignored:
- `.claude/rules/integration-testing.md`
- `.claude/agents/host-app-validator.md`
- `.claude/context/session-state.md`
- `.claude/settings.local.json`

## Typical Session Flow

1. **Session start** — Claude reads CLAUDE.md + session-state.md breadcrumbs from last session.
2. **Pick work** — Backlog-workflow skill guides item selection from OPTIMIZATION_BACKLOG.md.
3. **Implement** — TDD per Testing Workflow. Rules load contextually based on files touched.
4. **Validate** — Dispatch host-app-validator agent to a local or Docker host app with a specific plan.
5. **Review** — Dispatch doc-reviewer agent to check if docs need updating. Optionally dispatch code-optimizer for simplification ideas.
6. **Explore** — Dispatch use-case-explorer to find new extraction gaps or retrieval-designer to design query patterns.
7. **Session end** — Update session-state.md with breadcrumbs.

## Design Decisions

- **Skills over CLAUDE.md bloat.** Workflow instructions that exceed a few lines live in skills, referenced from CLAUDE.md. Keeps CLAUDE.md under 150 lines.
- **Agents propose, don't act.** code-optimizer, doc-reviewer, and retrieval-designer report findings. The human or main session decides what to implement. host-app-validator executes but only runs read-only validation.
- **Single validator agent, environment as parameter.** Local and Docker validation share the same workflow shape — only the commands differ.
- **Extractor-patterns stays as a rule, not a skill.** It's path-triggered, concise, and always relevant when touching extractors. No workflow guidance needed.
- **Privacy via .gitignore.** Files referencing local project paths and container names are not committed.
