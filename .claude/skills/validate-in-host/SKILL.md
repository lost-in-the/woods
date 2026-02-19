---
name: validate-in-host
description: Spawns a host-app-validator agent to run extraction validation in host-app or example-docker/admin
argument-hint: "[host-app|admin] [what-to-validate]"
allowed-tools: Task, Read
---
# Validate in Host App

Spawn a `host-app-validator` agent to validate extraction in a host Rails environment.

## Usage

`/validate-in-host [environment] [description]`

- `$ARGUMENTS[0]` = environment: `host-app` (default) or `admin`
- Remaining arguments = what to validate (e.g., "full pipeline", "model_extractor output", "new event_extractor")

If no arguments, default to `host-app` with full integration spec run.

## Workflow

1. **Parse arguments** — Determine environment and validation scope.
2. **Read the rules** — Read `.claude/rules/integration-testing.md` to get environment-specific commands.
3. **Build the plan** — Construct a validation plan based on the scope:

### For `host-app`

| Scope | Commands |
|---|---|
| Full pipeline | `cd ~/work/host-app && bundle exec rspec spec/integration/ --format json --out tmp/test_results.json` |
| Specific extractor | `cd ~/work/host-app && bundle exec rake codebase_index:extract` then inspect `tmp/codebase_index/` output |
| Stats/health | `cd ~/work/host-app && bundle exec rake codebase_index:stats && bundle exec rake codebase_index:validate` |

### For `admin`

| Scope | Commands |
|---|---|
| Full extraction | `cd ~/work/example-docker && docker compose exec app bin/rails codebase_index:extract` |
| Stats/health | `cd ~/work/example-docker && docker compose exec app bin/rails codebase_index:stats` |
| Console check | `cd ~/work/example-docker && docker compose exec app bin/rails codebase_index:validate` |

4. **Spawn the agent** — Use the Task tool with:
   - `subagent_type: "host-app-validator"`
   - A prompt containing: the environment, commands to run, what to look for, and what to report back

5. **Report results** — Summarize the agent's findings to the user.

## Example Prompts to Agent

### Full host-app validation
```
Validate CodebaseIndex extraction in host-app:
1. cd ~/work/host-app
2. Run: bundle exec rspec spec/integration/ --format progress --format json --out tmp/test_results.json
3. If any failures, read tmp/test_results.json and report the failing specs with error messages.
4. Run: bundle exec rake codebase_index:stats
5. Report: spec pass/fail counts and extraction stats.
```

### Specific extractor in admin
```
Validate the EventExtractor in example-docker/admin:
1. cd ~/work/example-docker
2. Verify container: docker compose ps
3. Run: docker compose exec app bin/rails codebase_index:extract
4. Check output for event-type units: docker compose exec app bin/rails runner "puts CodebaseIndex::Extractor.new.extract_all.select { |u| u.unit_type == 'event' }.count"
5. Report: count of event units, any errors during extraction.
```
