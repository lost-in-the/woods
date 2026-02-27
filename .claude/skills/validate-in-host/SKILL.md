---
name: validate-in-host
description: Spawns a host-app-validator agent to run extraction validation in a host Rails app (local or Docker)
argument-hint: "[host-app|admin] [what-to-validate]"
allowed-tools: Task, Read
---
# Validate in Host App

Spawn a `host-app-validator` agent to validate extraction in a host Rails environment.

## Usage

`/validate-in-host [environment] [description]`

- `$ARGUMENTS[0]` = environment: `local` (default) or `docker`
- Remaining arguments = what to validate (e.g., "full pipeline", "model_extractor output", "new event_extractor")

If no arguments, default to `host-app` with full integration spec run.

## Workflow

1. **Parse arguments** — Determine environment and validation scope.
2. **Read the rules** — Read `.claude/rules/integration-testing.md` to get environment-specific commands.
3. **Build the plan** — Construct a validation plan based on the scope:

### For `host-app`

| Scope | Commands |
|---|---|
| Full pipeline | `cd $HOST_APP_DIR && bundle exec rspec spec/integration/ --format json --out tmp/test_results.json` |
| Specific extractor | `cd $HOST_APP_DIR && bundle exec rake codebase_index:extract` then inspect `tmp/codebase_index/` output |
| Stats/health | `cd $HOST_APP_DIR && bundle exec rake codebase_index:stats && bundle exec rake codebase_index:validate` |

### For `docker`

| Scope | Commands |
|---|---|
| Full extraction | `cd $COMPOSE_DIR && docker compose exec $SERVICE bin/rails codebase_index:extract` |
| Stats/health | `cd $COMPOSE_DIR && docker compose exec $SERVICE bin/rails codebase_index:stats` |
| Console check | `cd $COMPOSE_DIR && docker compose exec $SERVICE bin/rails codebase_index:validate` |

4. **Spawn the agent** — Use the Task tool with:
   - `subagent_type: "host-app-validator"`
   - A prompt containing: the environment, commands to run, what to look for, and what to report back

5. **Report results** — Summarize the agent's findings to the user.

## Example Prompts to Agent

### Full local validation
```
Validate CodebaseIndex extraction in host app:
1. cd $HOST_APP_DIR
2. Run: bundle exec rspec spec/integration/ --format progress --format json --out tmp/test_results.json
3. If any failures, read tmp/test_results.json and report the failing specs with error messages.
4. Run: bundle exec rake codebase_index:stats
5. Report: spec pass/fail counts and extraction stats.
```

### Specific extractor in Docker
```
Validate the EventExtractor in a Docker host app:
1. cd $COMPOSE_DIR
2. Verify container: docker compose ps
3. Run: docker compose exec $SERVICE bin/rails codebase_index:extract
4. Check output for event-type units: docker compose exec $SERVICE bin/rails runner "puts CodebaseIndex::Extractor.new.extract_all.select { |u| u.unit_type == 'event' }.count"
5. Report: count of event units, any errors during extraction.
```
