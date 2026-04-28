# Liam ERD Integration — Phase 1 Design Spec

**Date:** 2026-04-06
**Branch:** `erd`
**Base:** `main`
**Scope:** Phase 1 (MVP) — models-only ERD served via Rack middleware

## Overview

Integrate [Liam ERD](https://github.com/liam-hq/liam) (Apache 2.0) into Woods as a development-only ERD visualization served via Rack middleware. Phase 1 renders the model/database layer using Liam's stock frontend. Phase 2+ extends the frontend for non-model unit types and flow visualization.

## Goals

- Serve an interactive ERD at a configurable path (default `/woods/erd`)
- Generate Liam-compatible `schema.json` from Woods' extracted model units
- Require no additional runtime dependencies beyond the Gemfile
- Handle large schemas (212+ models, hundreds of associations)
- Follow existing Woods middleware patterns (Railtie, lazy init, configurable)

## Non-Goals (Phase 1)

- Non-model unit types (controllers, jobs, services, etc.)
- Custom node rendering or Liam frontend modifications
- Deep-linkable URLs or agent-friendly URL generation
- Flow path highlighting

## Architecture

### Data Flow

```
Extracted JSON (tmp/woods/)
  → SchemaGenerator reads model units
  → Transforms to Liam schema format
  → Cached in memory
  → Served as schema.json by RackMiddleware
  → Liam SPA fetches schema.json on load
  → React Flow + ELK renders interactive ERD
```

### File Layout

```
lib/
├── woods/
│   ├── erd/
│   │   ├── rack_middleware.rb      # Serves assets + schema.json
│   │   └── schema_generator.rb    # Woods units → Liam schema format
│   └── railtie.rb                 # +1 initializer for woods.erd
vendor/
└── assets/
    └── liam-erd/                  # Pre-built Liam SPA (index.html, JS, CSS)
scripts/
└── build-liam-erd.sh              # Reproducible build from Liam source
```

## Components

### 1. Configuration

Two new attributes on `Woods::Configuration`:

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `erd_enabled` | Boolean | `false` | Enable ERD middleware |
| `erd_path` | String | `'/woods/erd'` | URL path to mount the ERD |

Usage in host app (no new initializer file required):

```ruby
Woods.configure do |config|
  config.erd_enabled = true
  config.erd_path = '/woods/erd'  # optional
end
```

### 2. Railtie Initializer

New initializer `woods.erd` in `lib/woods/railtie.rb`, same pattern as `woods.console_mcp`:

```ruby
initializer 'woods.erd' do |app|
  config = Woods.configuration
  if config.erd_enabled
    require 'woods/erd/rack_middleware'
    app.middleware.use(
      Woods::Erd::RackMiddleware,
      path: config.erd_path,
      output_dir: config.output_dir
    )
  end
end
```

### 3. Rack Middleware

`Woods::Erd::RackMiddleware` — simple static file server + dynamic schema endpoint.

**Routing logic:**
- `GET #{path}/` → serve `index.html` from vendored assets
- `GET #{path}/schema.json` → serve generated schema JSON (cached)
- `GET #{path}/assets/*` → serve static JS/CSS from vendored assets
- Everything else → `@app.call(env)`

**Content types:** Determined by file extension (`.html`, `.js`, `.css`, `.json`).

**Simpler than the console MCP middleware** — no MCP server, no eager_load, no model registry. Schema JSON is generated on first request and cached in an instance variable. No mutex needed since the cache is a simple string assignment (race conditions produce duplicate work at worst, not corruption).

### 4. Schema Generator

`Woods::Erd::SchemaGenerator` — reads extracted model units, produces Liam-compatible JSON.

**Input:** Woods extracted unit JSON files from `output_dir`, filtered to `type: "model"`.

**Output:** JSON matching Liam's `schemaSchema`:

```json
{
  "tables": {
    "<table_name>": {
      "name": "<table_name>",
      "comment": null,
      "columns": {
        "<col_name>": {
          "name": "<col_name>",
          "type": "<sql_type>",
          "default": null,
          "check": null,
          "notNull": true,
          "comment": null
        }
      },
      "indexes": {
        "<index_name>": {
          "name": "<index_name>",
          "unique": false,
          "columns": ["col_a", "col_b"],
          "type": ""
        }
      },
      "constraints": {
        "<constraint_name>": { ... }
      }
    }
  },
  "enums": {},
  "extensions": {}
}
```

**Mapping rules:**

| Woods metadata | Liam schema field | Notes |
|---------------|-------------------|-------|
| `metadata[:table_name]` | Table key + `name` | |
| `metadata[:columns]` | `columns` record | `null` → `notNull` (inverted) |
| `metadata[:primary_key]` | `PRIMARY KEY` constraint | |
| `metadata[:foreign_keys]` | `FOREIGN KEY` constraints | New metadata field (see below) |
| `metadata[:indexes]` | `indexes` record | New metadata field (see below) |
| `metadata[:enums]` | `enums` (top-level) | Rails enum definitions |
| `belongs_to` associations | Fallback FK generation | Used when `foreign_keys` metadata absent |

**Foreign key constraint generation:**
- Primary source: `metadata[:foreign_keys]` (structured data from `ActiveRecord::Base.connection.foreign_keys`)
- Fallback: Derive from `belongs_to` associations in `metadata[:associations]` — use `foreign_key` field for column, resolve target model's `table_name` for `targetTableName`
- Constraint naming: `fk_<table>_<column>` for generated constraints

**Handling missing data gracefully:**
- `indexes` metadata absent → skip indexes (pre-existing extractions)
- `foreign_keys` metadata absent → fall back to association-derived FKs
- Model without `table_exists: true` → skip entirely
- Duplicate `table_name` across STI models → include only the base model's table

### 5. Model Extractor Enhancement

Add two new keys to `extract_metadata` in `ModelExtractor`:

```ruby
# In extract_metadata, after columns:
indexes: if model.table_exists?
           ActiveRecord::Base.connection.indexes(model.table_name).map do |idx|
             { 'name' => idx.name, 'unique' => idx.unique, 'columns' => idx.columns }
           end
         else
           []
         end,
foreign_keys: if model.table_exists?
                ActiveRecord::Base.connection.foreign_keys(model.table_name).map do |fk|
                  {
                    'from_table' => fk.from_table,
                    'to_table' => fk.to_table,
                    'column' => fk.column,
                    'primary_key' => fk.primary_key,
                    'name' => fk.name,
                    'on_delete' => fk.on_delete,
                    'on_update' => fk.on_update
                  }
                end
              else
                []
              end,
```

Requires re-extraction to populate. Transform layer handles absence gracefully.

### 6. Vendored Assets

Pre-built Liam CLI SPA checked into `vendor/assets/liam-erd/`. Built from `@liam-hq/cli` package.

**Build process** (documented in `scripts/build-liam-erd.sh`):
1. Clone `liam-hq/liam` at a pinned version/commit
2. `pnpm install && pnpm build` in `frontend/packages/cli`
3. Copy `dist-cli/html/*` to `vendor/assets/liam-erd/`
4. Set build-time env vars: `VITE_CLI_VERSION_VERSION=woods-embedded`, `VITE_CLI_VERSION_ENV_NAME=woods`

**Gemspec change:** Add `vendor/assets/liam-erd/**/*` to `spec.files`.

**Asset size:** Estimated ~2-5MB (typical Vite SPA with React Flow + ELK).

## Edge Cases

- **No extraction run yet:** Middleware returns a JSON error response with a message to run `rake woods:extract` first.
- **STI models:** Multiple models sharing one table — include the table once, not per-subclass.
- **Polymorphic associations:** Skip FK constraint generation for polymorphic `belongs_to` (no single target table).
- **Models without tables:** Skip models where `table_exists: false`.
- **MySQL vs PostgreSQL:** Column types will differ in `sql_type` format. Liam treats `type` as a display string, so this is cosmetic only.
- **Large schema performance:** 212 models with ~50 columns average = ~10,000 columns. The ELK layout engine handles this scale (designed for 100+ tables). JSON payload estimated at 200-500KB.

## Testing

- **Unit specs for SchemaGenerator:** Test mapping logic with mock extracted units. Cover: column type mapping, FK generation from associations, FK generation from structured metadata, STI dedup, polymorphic skip, missing metadata graceful degradation.
- **Unit specs for RackMiddleware:** Test routing (index.html, schema.json, static assets, pass-through). Test content types. Test schema caching.
- **Integration validation:** After implementation, run extraction in host-woods container, update gem branch, verify ERD renders at configured path.

## Changes to Existing Files

| File | Change |
|------|--------|
| `lib/woods.rb` | Add `erd_enabled`, `erd_path` to Configuration |
| `lib/woods/railtie.rb` | Add `woods.erd` initializer |
| `lib/woods/extractors/model_extractor.rb` | Add `indexes`, `foreign_keys` to metadata |
| `woods.gemspec` | Add `vendor/assets/liam-erd/**/*` to `spec.files` |

## New Files

| File | Purpose |
|------|---------|
| `lib/woods/erd/rack_middleware.rb` | Serves ERD assets + schema.json |
| `lib/woods/erd/schema_generator.rb` | Woods units → Liam schema format |
| `vendor/assets/liam-erd/*` | Pre-built Liam SPA |
| `scripts/build-liam-erd.sh` | Reproducible asset build |
| `spec/erd/rack_middleware_spec.rb` | Middleware routing specs |
| `spec/erd/schema_generator_spec.rb` | Transform logic specs |

## Future Phases (Out of Scope)

- **Phase 2:** Fork `@liam-hq/erd-core`, add non-table node types with type-aware rendering, toggle UI for unit type layers, dependency edges across all types
- **Phase 3:** Deep-linkable URLs (`?focus=OrdersController&depth=2`), agent-friendly URL generation, flow path highlighting

## Decision Log

See `docs/superpowers/specs/2026-04-06-liam-erd-decisions.md` for all design decisions with rationale.
