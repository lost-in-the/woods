# Liam ERD Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Woods ERD visualization with non-model unit types (controllers, jobs, services, mailers) rendered as color-coded card nodes, toolbar layer toggles, sidebar focus mode, and cross-type dependency edges.

**Architecture:** Ruby `SchemaGenerator` extended to read Tier 1 extraction directories and output a `nodes` key alongside existing `tables`. Shallow fork of Liam ERD packages (erd-core, ui, schema, cli) into `frontend/liam-erd/` with custom `WoodsNode` React Flow component, toolbar layer controls, and focus mode. Build script updated to compile from local fork.

**Tech Stack:** Ruby/Rack (schema generation), React 19 + React Flow + ELK (visualization), TypeScript, Vite (build), pnpm (package manager)

**Spec:** `docs/superpowers/specs/2026-04-06-liam-erd-phase2-design.md`
**Decisions:** `docs/superpowers/specs/2026-04-06-liam-erd-phase2-decisions.md`

---

## File Structure

### Ruby (modified)

| File | Responsibility |
|------|---------------|
| `lib/woods.rb:38-82` | Add `erd_layers` config attribute |
| `lib/woods/erd/schema_generator.rb` | Extend to read Tier 1 units, output `nodes` |
| `spec/configuration_spec.rb` | Test `erd_layers` defaults |
| `spec/erd/schema_generator_spec.rb` | Test node generation, layer filtering, dependency mapping |
| `scripts/build-liam-erd.sh` | Build from local fork instead of upstream |

### Frontend (new — `frontend/liam-erd/`)

| File | Responsibility |
|------|---------------|
| `packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/` | Custom React Flow node for non-model units |
| `packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNode.tsx` | Main node component |
| `packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNodeHeader.tsx` | Color-coded header bar |
| `packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/WoodsNodeMemberList.tsx` | Simplified member rows |
| `packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/woodsNodeColors.ts` | WCAG color palette per type |
| `packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/index.ts` | Barrel export |
| `packages/erd-core/src/features/erd/components/LayerToggle/` | Toolbar dropdown for layer + edge toggles |
| `packages/erd-core/src/features/erd/components/FocusMode/` | Focus mode state + Exit Focus UI |
| `packages/schema/src/schema/nodes.ts` | TypeScript types for `nodes` schema extension |

---

### Task 1: Add `erd_layers` configuration

**Files:**
- Modify: `lib/woods.rb:38-82`
- Test: `spec/configuration_spec.rb`

- [ ] **Step 1: Write failing test for `erd_layers` default**

In `spec/configuration_spec.rb`, inside the `describe 'default values'` block (after the `erd_path` test at line 64), add:

```ruby
it 'sets erd_layers to [:models]' do
  expect(config.erd_layers).to eq([:models])
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/configuration_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: 1 failure — `NoMethodError: undefined method 'erd_layers'`

- [ ] **Step 3: Add `erd_layers` to Configuration**

In `lib/woods.rb`, add `erd_layers` to the `attr_accessor` line (line 39):

```ruby
attr_accessor :embedding_model, :include_framework_sources, :gem_configs,
              :vector_store, :metadata_store, :graph_store, :embedding_provider, :log_level,
              :vector_store_options, :metadata_store_options, :embedding_options,
              :concurrent_extraction, :precompute_flows, :enable_snapshots,
              :session_tracer_enabled, :session_store, :session_id_proc, :session_exclude_paths,
              :console_mcp_enabled, :console_mcp_path, :console_redacted_columns,
              :notion_api_token, :notion_database_ids,
              :unblocked_api_token, :unblocked_collection_id, :unblocked_repo_url,
              :cache_store, :cache_options, :erd_enabled, :erd_path, :erd_layers
```

In `initialize` (after `@erd_path = '/woods/erd'` at line 81), add:

```ruby
@erd_layers = [:models]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/configuration_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/woods.rb spec/configuration_spec.rb
git commit -m "Add erd_layers configuration option for non-model unit types"
```

---

### Task 2: Extend SchemaGenerator — node generation for controllers

**Files:**
- Modify: `lib/woods/erd/schema_generator.rb`
- Test: `spec/erd/schema_generator_spec.rb`

This task adds the `nodes` infrastructure and controller node generation. Later tasks add job/service/mailer support.

- [ ] **Step 1: Add helper to write non-model unit fixtures**

In `spec/erd/schema_generator_spec.rb`, after the existing `write_model_unit` helper (line 35), add:

```ruby
def write_unit(type, identifier, metadata: {}, dependencies: [])
  type_dir = File.join(output_dir, "#{type}s")
  FileUtils.mkdir_p(type_dir)

  unit = {
    'type' => type.to_s,
    'identifier' => identifier,
    'metadata' => metadata,
    'dependencies' => dependencies
  }

  digest = Digest::SHA256.hexdigest(identifier)[0, 8]
  filename = "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}_#{digest}.json"
  File.write(File.join(type_dir, filename), JSON.generate(unit))
end
```

- [ ] **Step 2: Write failing test for controller node generation**

In the same spec file, add a new describe block after the existing `describe '#generate'` block:

```ruby
describe '#generate with nodes' do
  before do
    write_model_unit('Order', {
      'table_name' => 'orders',
      'table_exists' => true,
      'primary_key' => 'id',
      'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
      'associations' => [],
      'indexes' => [],
      'foreign_keys' => [],
      'enums' => {}
    })
  end

  it 'generates controller nodes with actions as members' do
    write_unit(:controller, 'OrdersController',
      metadata: {
        'actions' => %w[index show create],
        'action_count' => 3,
        'filters' => [],
        'routes' => {}
      },
      dependencies: [
        { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
      ])

    schema = described_class.new(output_dir, layers: [:models, :controllers]).generate

    expect(schema).to have_key('nodes')
    expect(schema['nodes']).to have_key('OrdersController')

    node = schema['nodes']['OrdersController']
    expect(node['name']).to eq('OrdersController')
    expect(node['type']).to eq('controller')
    expect(node['members']).to eq([
      { 'name' => 'index' },
      { 'name' => 'show' },
      { 'name' => 'create' }
    ])
    expect(node['meta']).to eq({ 'action_count' => 3 })
    expect(node['dependencies']).to include(
      hash_including('target' => 'orders', 'target_type' => 'table', 'via' => 'code_reference')
    )
  end

  it 'excludes nodes when layer is not active' do
    write_unit(:controller, 'OrdersController',
      metadata: { 'actions' => %w[index], 'action_count' => 1 },
      dependencies: [])

    schema = described_class.new(output_dir, layers: [:models]).generate

    expect(schema).not_to have_key('nodes')
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bundle exec rspec spec/erd/schema_generator_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: 2 failures — `ArgumentError: wrong number of arguments` (for `layers:` param) and/or missing `nodes` key

- [ ] **Step 4: Add `layers` parameter and node infrastructure to SchemaGenerator**

Replace the `SchemaGenerator` class in `lib/woods/erd/schema_generator.rb` with:

```ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Erd
    # Transforms Woods extracted units into Liam ERD's extended schema format.
    #
    # Reads model unit JSON files from the extraction output directory and
    # produces a schema conforming to Liam's schemaSchema (tables, columns,
    # indexes, constraints). When additional layers are enabled, also reads
    # non-model units and produces a `nodes` key with type-aware entries.
    #
    # @example Models only (default)
    #   generator = SchemaGenerator.new("/app/tmp/woods")
    #   schema = generator.generate
    #   # => { "tables" => { ... }, "enums" => {}, "extensions" => {} }
    #
    # @example With controller nodes
    #   generator = SchemaGenerator.new("/app/tmp/woods", layers: [:models, :controllers])
    #   schema = generator.generate
    #   # => { "tables" => { ... }, "nodes" => { ... }, "enums" => {}, "extensions" => {} }
    #
    class SchemaGenerator
      # Maps layer symbols to extraction output subdirectory names
      LAYER_DIRECTORIES = {
        controllers: 'controllers',
        jobs: 'jobs',
        services: 'services',
        mailers: 'mailers'
      }.freeze

      # @param output_dir [String, Pathname] Path to Woods extraction output directory
      # @param layers [Array<Symbol>] Unit type layers to include (default: [:models])
      def initialize(output_dir, layers: [:models])
        @output_dir = Pathname.new(output_dir)
        @layers = layers
      end

      # Generate a Liam-compatible schema hash from extracted units.
      #
      # @return [Hash] Schema with tables, optionally nodes, enums, and extensions keys
      # @raise [Woods::Error] if no extracted model data is found
      def generate
        models_dir = @output_dir.join('models')
        raise Woods::Error, 'No extracted model data found in output directory' unless models_dir.directory?

        units = load_model_units(models_dir)
        tables = build_tables(units)
        enums = build_enums(units)

        schema = { 'tables' => tables, 'enums' => enums, 'extensions' => {} }

        non_model_layers = @layers - [:models]
        if non_model_layers.any?
          table_lookup = build_table_lookup(units)
          nodes = build_nodes(non_model_layers, table_lookup)
          schema['nodes'] = nodes if nodes.any?
        end

        schema
      end

      private

      def load_model_units(models_dir)
        models_dir.children
                  .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                  .map { |f| JSON.parse(f.read) }
      end

      def build_tables(units)
        tables = {}

        prioritize_base_models(units).each do |unit|
          meta = unit['metadata'] || {}
          table_name = meta['table_name']
          next if table_name.nil?
          next unless meta['table_exists']
          next if tables.key?(table_name)

          tables[table_name] = build_table(table_name, meta, units)
        end

        tables
      end

      def prioritize_base_models(units)
        units.sort_by { |u| u.dig('metadata', 'is_sti_child') ? 1 : 0 }
      end

      def build_table(table_name, meta, all_units)
        {
          'name' => table_name,
          'comment' => nil,
          'columns' => build_columns(meta['columns'] || []),
          'indexes' => build_indexes(meta['indexes'] || []),
          'constraints' => build_constraints(table_name, meta, all_units)
        }
      end

      def build_columns(columns)
        columns.each_with_object({}) do |col, hash|
          name = col['name']
          hash[name] = {
            'name' => name,
            'type' => col['type'] || 'unknown',
            'default' => col['default'],
            'check' => nil,
            'notNull' => !col['null'],
            'comment' => nil
          }
        end
      end

      def build_indexes(indexes)
        indexes.each_with_object({}) do |idx, hash|
          name = idx['name']
          hash[name] = {
            'name' => name,
            'unique' => idx['unique'] || false,
            'columns' => idx['columns'] || [],
            'type' => ''
          }
        end
      end

      def build_constraints(table_name, meta, all_units)
        constraints = {}

        pk = meta['primary_key']
        if pk
          pk_name = "#{table_name}_pkey"
          constraints[pk_name] = {
            'type' => 'PRIMARY KEY',
            'name' => pk_name,
            'columnNames' => Array(pk)
          }
        end

        if meta.key?('foreign_keys') && !meta['foreign_keys'].empty?
          build_foreign_keys_from_metadata(meta['foreign_keys'], constraints)
        else
          build_foreign_keys_from_associations(table_name, meta, all_units, constraints)
        end

        constraints
      end

      def build_foreign_keys_from_metadata(foreign_keys, constraints)
        foreign_keys.each do |fk|
          name = fk['name'] || "fk_#{fk['from_table']}_#{fk['column']}"
          constraints[name] = {
            'type' => 'FOREIGN KEY',
            'name' => name,
            'columnNames' => [fk['column']],
            'targetTableName' => fk['to_table'],
            'targetColumnNames' => [fk['primary_key'] || 'id'],
            'updateConstraint' => map_fk_action(fk['on_update']),
            'deleteConstraint' => map_fk_action(fk['on_delete'])
          }
        end
      end

      def build_foreign_keys_from_associations(table_name, meta, all_units, constraints)
        associations = meta['associations'] || []
        table_lookup = build_table_lookup(all_units)

        associations.each do |assoc|
          next unless assoc['type'].to_s == 'belongs_to'
          next if assoc['polymorphic']

          foreign_key = assoc['foreign_key']
          target_table = table_lookup[assoc['target']]
          next unless target_table

          name = "fk_#{table_name}_#{foreign_key}"
          constraints[name] = {
            'type' => 'FOREIGN KEY',
            'name' => name,
            'columnNames' => [foreign_key],
            'targetTableName' => target_table,
            'targetColumnNames' => ['id'],
            'updateConstraint' => 'NO_ACTION',
            'deleteConstraint' => 'NO_ACTION'
          }
        end
      end

      def build_table_lookup(units)
        units.each_with_object({}) do |unit, lookup|
          meta = unit['metadata'] || {}
          next unless meta['table_exists']

          lookup[unit['identifier']] = meta['table_name']
        end
      end

      def build_enums(units)
        enums = {}

        units.each do |unit|
          model_enums = unit.dig('metadata', 'enums') || {}
          model_enums.each do |name, values|
            qualified_name = "#{unit['identifier']}.#{name}"
            enums[qualified_name] = {
              'name' => qualified_name,
              'values' => values.is_a?(Hash) ? values.keys : Array(values),
              'comment' => nil
            }
          end
        end

        enums
      end

      def map_fk_action(action)
        case action.to_s
        when 'cascade' then 'CASCADE'
        when 'restrict' then 'RESTRICT'
        when 'nullify', 'set_null' then 'SET_NULL'
        when 'set_default' then 'SET_DEFAULT'
        else 'NO_ACTION'
        end
      end

      # --- Non-model node generation ---

      def build_nodes(layers, table_lookup)
        nodes = {}

        layers.each do |layer|
          dir_name = LAYER_DIRECTORIES[layer]
          next unless dir_name

          layer_dir = @output_dir.join(dir_name)
          next unless layer_dir.directory?

          load_units(layer_dir).each do |unit|
            identifier = unit['identifier']
            next unless identifier

            nodes[identifier] = build_node(unit, layer, table_lookup)
          end
        end

        nodes
      end

      def load_units(dir)
        dir.children
           .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
           .map { |f| JSON.parse(f.read) }
      end

      def build_node(unit, layer, table_lookup)
        meta = unit['metadata'] || {}
        deps = unit['dependencies'] || []

        {
          'name' => unit['identifier'],
          'type' => layer.to_s.delete_suffix('s'),
          'members' => build_node_members(layer, meta),
          'meta' => build_node_meta(layer, meta),
          'dependencies' => build_node_dependencies(deps, table_lookup)
        }
      end

      def build_node_members(layer, meta)
        case layer
        when :controllers
          (meta['actions'] || []).map { |a| { 'name' => a } }
        when :jobs
          (meta['perform_params'] || []).map { |p| { 'name' => p } }
        when :services
          (meta['public_methods'] || []).map { |m| { 'name' => m } }
        when :mailers
          (meta['actions'] || []).map { |a| { 'name' => a } }
        else
          []
        end
      end

      def build_node_meta(layer, meta)
        case layer
        when :controllers
          { 'action_count' => meta['action_count'] || 0 }
        when :jobs
          result = {}
          result['queue'] = meta['queue'] if meta['queue']
          result['job_type'] = meta['job_type'] if meta['job_type']
          result
        when :services
          result = {}
          result['callable'] = true if meta['is_callable']
          result
        when :mailers
          result = {}
          result['delivery_method'] = meta['delivery_method'] if meta['delivery_method']
          result['action_count'] = meta['action_count'] || 0
          result
        else
          {}
        end
      end

      def build_node_dependencies(deps, table_lookup)
        deps.map do |dep|
          target = dep['target']
          via = dep['via']

          # Resolve target to table name if it's a model dependency
          resolved_target = table_lookup[target] || target
          target_type = table_lookup.key?(target) ? 'table' : dep['type'] || 'unknown'

          { 'target' => resolved_target, 'target_type' => target_type, 'via' => via }
        end
      end
    end
  end
end
```

- [ ] **Step 5: Update RackMiddleware to pass `layers` to SchemaGenerator**

In `lib/woods/erd/rack_middleware.rb`, update the `generate_schema` method (line 114):

```ruby
def generate_schema
  layers = if defined?(Woods) && Woods.respond_to?(:configuration)
             Woods.configuration.erd_layers
           else
             [:models]
           end
  schema = SchemaGenerator.new(@output_dir, layers: layers).generate
  JSON.generate(schema)
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/erd/schema_generator_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All pass (both existing table tests and new node tests)

- [ ] **Step 7: Commit**

```bash
git add lib/woods/erd/schema_generator.rb lib/woods/erd/rack_middleware.rb spec/erd/schema_generator_spec.rb
git commit -m "Extend SchemaGenerator with nodes for controller units"
```

---

### Task 3: Add node generation for jobs, services, and mailers

**Files:**
- Modify: `spec/erd/schema_generator_spec.rb`
- (No code changes needed — `build_node_members` and `build_node_meta` already handle all 4 types from Task 2)

- [ ] **Step 1: Write tests for job node generation**

In `spec/erd/schema_generator_spec.rb`, inside the `describe '#generate with nodes'` block, add:

```ruby
it 'generates job nodes with perform params as members' do
  write_unit(:job, 'OrderSyncJob',
    metadata: {
      'perform_params' => %w[order_id force],
      'queue' => 'critical',
      'job_type' => 'sidekiq'
    },
    dependencies: [
      { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
    ])

  schema = described_class.new(output_dir, layers: [:models, :jobs]).generate

  expect(schema['nodes']).to have_key('OrderSyncJob')
  node = schema['nodes']['OrderSyncJob']
  expect(node['type']).to eq('job')
  expect(node['members']).to eq([{ 'name' => 'order_id' }, { 'name' => 'force' }])
  expect(node['meta']).to eq({ 'queue' => 'critical', 'job_type' => 'sidekiq' })
end
```

- [ ] **Step 2: Write tests for service node generation**

```ruby
it 'generates service nodes with public methods as members' do
  write_unit(:service, 'OrderCreator',
    metadata: {
      'public_methods' => %w[call validate],
      'is_callable' => true
    },
    dependencies: [
      { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
    ])

  schema = described_class.new(output_dir, layers: [:models, :services]).generate

  expect(schema['nodes']).to have_key('OrderCreator')
  node = schema['nodes']['OrderCreator']
  expect(node['type']).to eq('service')
  expect(node['members']).to eq([{ 'name' => 'call' }, { 'name' => 'validate' }])
  expect(node['meta']).to eq({ 'callable' => true })
end
```

- [ ] **Step 3: Write tests for mailer node generation**

```ruby
it 'generates mailer nodes with mail actions as members' do
  write_unit(:mailer, 'OrderMailer',
    metadata: {
      'actions' => %w[confirmation receipt],
      'action_count' => 2,
      'delivery_method' => 'smtp'
    },
    dependencies: [
      { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
    ])

  schema = described_class.new(output_dir, layers: [:models, :mailers]).generate

  expect(schema['nodes']).to have_key('OrderMailer')
  node = schema['nodes']['OrderMailer']
  expect(node['type']).to eq('mailer')
  expect(node['members']).to eq([{ 'name' => 'confirmation' }, { 'name' => 'receipt' }])
  expect(node['meta']).to include('delivery_method' => 'smtp', 'action_count' => 2)
end
```

- [ ] **Step 4: Write test for multiple layers combined**

```ruby
it 'generates nodes for all active layers' do
  write_unit(:controller, 'OrdersController',
    metadata: { 'actions' => %w[index], 'action_count' => 1 },
    dependencies: [])
  write_unit(:job, 'OrderSyncJob',
    metadata: { 'perform_params' => %w[order_id], 'queue' => 'default' },
    dependencies: [])

  schema = described_class.new(output_dir, layers: [:models, :controllers, :jobs]).generate

  expect(schema['nodes']).to have_key('OrdersController')
  expect(schema['nodes']).to have_key('OrderSyncJob')
end
```

- [ ] **Step 5: Write test for graceful handling of missing directories**

```ruby
it 'skips layers with no extraction directory' do
  schema = described_class.new(output_dir, layers: [:models, :controllers, :jobs]).generate

  expect(schema).not_to have_key('nodes')
end
```

- [ ] **Step 6: Write test for node with no dependencies**

```ruby
it 'generates nodes with empty dependencies array' do
  write_unit(:service, 'Standalone',
    metadata: { 'public_methods' => %w[run], 'is_callable' => false },
    dependencies: [])

  schema = described_class.new(output_dir, layers: [:models, :services]).generate

  expect(schema['nodes']['Standalone']['dependencies']).to eq([])
end
```

- [ ] **Step 7: Run all tests**

Run: `bundle exec rspec spec/erd/schema_generator_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add spec/erd/schema_generator_spec.rb
git commit -m "Add tests for job, service, and mailer node generation"
```

---

### Task 4: Set up shallow fork of Liam ERD

**Files:**
- Create: `frontend/liam-erd/` (forked from upstream)

This task establishes the working frontend project. It requires Node.js >= 18 and pnpm >= 10.

- [ ] **Step 1: Clone upstream Liam and identify packages to copy**

```bash
TEMP_DIR=$(mktemp -d)
git clone --depth 1 --branch "@liam-hq/cli@0.7.9" https://github.com/liam-hq/liam.git "$TEMP_DIR/liam" 2>/dev/null || {
  git clone --depth 100 https://github.com/liam-hq/liam.git "$TEMP_DIR/liam"
}
ls "$TEMP_DIR/liam/frontend/packages/"
```

Identify exact package names. We need: `erd-core`, `ui`, `cli`, and `schema` (or whatever the schema/db-structure package is called).

- [ ] **Step 2: Create `frontend/liam-erd/` directory structure**

```bash
mkdir -p frontend/liam-erd/packages
```

Copy the 4 required packages:

```bash
cp -r "$TEMP_DIR/liam/frontend/packages/erd-core" frontend/liam-erd/packages/
cp -r "$TEMP_DIR/liam/frontend/packages/ui" frontend/liam-erd/packages/
cp -r "$TEMP_DIR/liam/frontend/packages/cli" frontend/liam-erd/packages/
cp -r "$TEMP_DIR/liam/frontend/packages/schema" frontend/liam-erd/packages/
```

If `schema` doesn't exist at that path, check `db-structure` or search for the package that exports `schemaSchema`. Copy any additional internal packages that erd-core imports (check `package.json` dependencies starting with `@liam-hq/`).

- [ ] **Step 3: Create root workspace `package.json`**

Create `frontend/liam-erd/package.json`:

```json
{
  "name": "woods-liam-erd",
  "private": true,
  "packageManager": "pnpm@10.0.0",
  "scripts": {
    "build": "pnpm --filter @liam-hq/cli build",
    "dev": "pnpm --filter @liam-hq/cli dev"
  }
}
```

- [ ] **Step 4: Create `pnpm-workspace.yaml`**

Create `frontend/liam-erd/pnpm-workspace.yaml`:

```yaml
packages:
  - "packages/*"
```

- [ ] **Step 5: Update workspace package references**

In each package's `package.json`, replace `workspace:*` references with relative paths or `workspace:*` (pnpm workspaces handle this). Remove any `@liam-hq/*` dependencies that reference packages we didn't copy. If a package references `@liam-hq/neverthrow` or similar utilities, check if we can replace with the npm `neverthrow` package directly or copy the internal package.

- [ ] **Step 6: Install dependencies and verify build**

```bash
cd frontend/liam-erd
pnpm install
pnpm build
```

If the build fails, diagnose missing dependencies. Common issues:
- Missing `@liam-hq/*` internal packages — copy them or replace with npm equivalents
- Turbo references — remove turbo config, use pnpm scripts directly
- Build order — cli depends on erd-core which depends on ui; pnpm resolves this via workspace protocol

- [ ] **Step 7: Verify built assets match Phase 1 output**

```bash
ls -la packages/cli/dist-cli/html/
```

The output should contain `index.html`, `assets/` directory with JS/CSS bundles — same structure as current `vendor/assets/liam-erd/`.

- [ ] **Step 8: Add `.gitignore` for node_modules**

Create `frontend/liam-erd/.gitignore`:

```
node_modules/
dist/
dist-cli/
.turbo/
*.tsbuildinfo
```

- [ ] **Step 9: Commit the fork**

```bash
git add frontend/liam-erd/
git commit -m "Add shallow fork of Liam ERD packages (erd-core, ui, schema, cli)"
```

---

### Task 5: Extend schema types for `nodes`

**Files:**
- Create: `frontend/liam-erd/packages/schema/src/nodes.ts` (or modify existing schema types)

- [ ] **Step 1: Locate the schema type definitions**

Find where `Table`, `Column`, `Schema` types are defined in the schema package:

```bash
grep -r "export.*type.*Table\b" frontend/liam-erd/packages/schema/src/ --include="*.ts"
grep -r "export.*interface.*Schema" frontend/liam-erd/packages/schema/src/ --include="*.ts"
```

- [ ] **Step 2: Add `WoodsNode` type definition**

Create `frontend/liam-erd/packages/schema/src/nodes.ts`:

```typescript
export interface WoodsNodeMember {
  name: string
}

export interface WoodsNodeDependency {
  target: string
  target_type: 'table' | 'controller' | 'job' | 'service' | 'mailer' | 'unknown'
  via: string
}

export type WoodsNodeType = 'controller' | 'job' | 'service' | 'mailer'

export interface WoodsNode {
  name: string
  type: WoodsNodeType
  members: WoodsNodeMember[]
  meta: Record<string, unknown>
  dependencies: WoodsNodeDependency[]
}

export type WoodsNodes = Record<string, WoodsNode>
```

- [ ] **Step 3: Extend the main schema type**

Find the existing schema type (likely something like `type Schema = { tables: Tables; enums: Enums; extensions: Extensions }`) and add:

```typescript
import type { WoodsNodes } from './nodes'

// Add to existing Schema type:
nodes?: WoodsNodes
```

The `nodes` field is optional so existing schemas (without nodes) remain valid.

- [ ] **Step 4: Export from package index**

Add to the schema package's main `index.ts`:

```typescript
export type { WoodsNode, WoodsNodeType, WoodsNodeMember, WoodsNodeDependency, WoodsNodes } from './nodes'
```

- [ ] **Step 5: Verify types compile**

```bash
cd frontend/liam-erd/packages/schema
pnpm tsc --noEmit
```

- [ ] **Step 6: Commit**

```bash
git add frontend/liam-erd/packages/schema/
git commit -m "Add WoodsNode types to schema package for non-model units"
```

---

### Task 6: Create WoodsNode React Flow component

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/`

- [ ] **Step 1: Study existing TableNode structure**

Read the existing TableNode to understand the component pattern:

```bash
find frontend/liam-erd/packages/erd-core -type f -name "TableNode*" -o -name "tableNode*"
```

Read `TableNode.tsx`, `TableHeader.tsx` (or equivalent) to understand:
- How React Flow `NodeProps` are used
- How the node registers with React Flow (via `nodeTypes` map)
- Styling approach (CSS modules? styled-components? Tailwind?)

- [ ] **Step 2: Create the color palette module**

Create `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/components/WoodsNode/woodsNodeColors.ts`:

```typescript
import type { WoodsNodeType } from '@liam-hq/schema'

export interface WoodsNodeColorScheme {
  header: string      // Header background
  headerText: string  // Header text (WCAG 4.5:1 against header)
  border: string      // Node border
  borderHover: string // Hover accent (distinct from all type colors)
}

// WCAG AA compliant against dark background (~#1a1a2e)
// Header colors: 3:1 minimum contrast for UI elements
// Text: 4.5:1 minimum contrast
export const WOODS_NODE_COLORS: Record<WoodsNodeType, WoodsNodeColorScheme> = {
  controller: {
    header: '#2563eb',     // Blue-600
    headerText: '#ffffff',
    border: '#60a5fa',     // Blue-400
    borderHover: '#e2e8f0',
  },
  job: {
    header: '#d97706',     // Amber-600
    headerText: '#ffffff',
    border: '#fbbf24',     // Amber-400
    borderHover: '#e2e8f0',
  },
  service: {
    header: '#9333ea',     // Purple-600
    headerText: '#ffffff',
    border: '#c084fc',     // Purple-400
    borderHover: '#e2e8f0',
  },
  mailer: {
    header: '#db2777',     // Pink-600
    headerText: '#ffffff',
    border: '#f472b6',     // Pink-400
    borderHover: '#e2e8f0',
  },
}

export const HOVER_ACCENT = '#e2e8f0' // Slate-200 — neutral, distinct from all type colors
```

- [ ] **Step 3: Create the WoodsNodeHeader component**

Create `WoodsNodeHeader.tsx`:

```tsx
import type { WoodsNodeType } from '@liam-hq/schema'
import { WOODS_NODE_COLORS } from './woodsNodeColors'

interface WoodsNodeHeaderProps {
  name: string
  type: WoodsNodeType
  meta: Record<string, unknown>
}

export function WoodsNodeHeader({ name, type, meta }: WoodsNodeHeaderProps) {
  const colors = WOODS_NODE_COLORS[type]

  return (
    <div
      style={{
        backgroundColor: colors.header,
        color: colors.headerText,
        padding: '8px 12px',
        borderRadius: '6px 6px 0 0',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: '8px',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
        <span style={{ fontSize: '10px', textTransform: 'uppercase', opacity: 0.8 }}>
          {type}
        </span>
        <span style={{ fontWeight: 600, fontSize: '13px' }}>{name}</span>
      </div>
      {renderMeta(type, meta)}
    </div>
  )
}

function renderMeta(type: WoodsNodeType, meta: Record<string, unknown>) {
  switch (type) {
    case 'controller':
      return meta.action_count != null ? (
        <span style={{ fontSize: '11px', opacity: 0.7 }}>{String(meta.action_count)} actions</span>
      ) : null
    case 'job':
      return meta.queue ? (
        <span style={{ fontSize: '11px', opacity: 0.7 }}>{String(meta.queue)}</span>
      ) : null
    case 'service':
      return meta.callable ? (
        <span style={{ fontSize: '11px', opacity: 0.7 }}>callable</span>
      ) : null
    case 'mailer':
      return meta.action_count != null ? (
        <span style={{ fontSize: '11px', opacity: 0.7 }}>{String(meta.action_count)} actions</span>
      ) : null
    default:
      return null
  }
}
```

- [ ] **Step 4: Create the WoodsNodeMemberList component**

Create `WoodsNodeMemberList.tsx`:

```tsx
import type { WoodsNodeMember } from '@liam-hq/schema'

interface WoodsNodeMemberListProps {
  members: WoodsNodeMember[]
}

export function WoodsNodeMemberList({ members }: WoodsNodeMemberListProps) {
  if (members.length === 0) return null

  return (
    <div style={{ padding: '4px 0' }}>
      {members.map((member) => (
        <div
          key={member.name}
          style={{
            padding: '4px 12px',
            fontSize: '12px',
            color: '#cbd5e1',
            borderBottom: '1px solid rgba(255,255,255,0.06)',
          }}
        >
          {member.name}
        </div>
      ))}
    </div>
  )
}
```

- [ ] **Step 5: Create the main WoodsNode component**

Create `WoodsNode.tsx`:

```tsx
import { Handle, Position, type NodeProps } from '@xyflow/react'
import type { WoodsNode as WoodsNodeType, WoodsNodeMember, WoodsNodeDependency } from '@liam-hq/schema'
import { WOODS_NODE_COLORS } from './woodsNodeColors'
import { WoodsNodeHeader } from './WoodsNodeHeader'
import { WoodsNodeMemberList } from './WoodsNodeMemberList'

export interface WoodsNodeData {
  name: string
  type: WoodsNodeType['type']
  members: WoodsNodeMember[]
  meta: Record<string, unknown>
  dependencies: WoodsNodeDependency[]
}

export function WoodsNode({ data }: NodeProps) {
  const nodeData = data as unknown as WoodsNodeData
  const colors = WOODS_NODE_COLORS[nodeData.type]

  return (
    <div
      style={{
        backgroundColor: '#1e1e2e',
        border: `1px solid ${colors.border}`,
        borderRadius: '6px',
        minWidth: '200px',
        maxWidth: '300px',
        overflow: 'hidden',
      }}
    >
      <Handle type="target" position={Position.Left} style={{ visibility: 'hidden' }} />
      <WoodsNodeHeader name={nodeData.name} type={nodeData.type} meta={nodeData.meta} />
      <WoodsNodeMemberList members={nodeData.members} />
      <Handle type="source" position={Position.Right} style={{ visibility: 'hidden' }} />
    </div>
  )
}
```

- [ ] **Step 6: Create barrel export**

Create `index.ts`:

```typescript
export { WoodsNode } from './WoodsNode'
export type { WoodsNodeData } from './WoodsNode'
export { WOODS_NODE_COLORS, HOVER_ACCENT } from './woodsNodeColors'
```

- [ ] **Step 7: Register WoodsNode with React Flow**

Find where `nodeTypes` is defined in erd-core (likely near the `<ReactFlow>` component render):

```bash
grep -r "nodeTypes" frontend/liam-erd/packages/erd-core/src/ --include="*.ts" --include="*.tsx" -l
```

Add the WoodsNode to the `nodeTypes` map:

```typescript
import { WoodsNode } from './components/WoodsNode'

// Add to existing nodeTypes object:
const nodeTypes = {
  // ... existing types
  woodsNode: WoodsNode,
}
```

- [ ] **Step 8: Verify build**

```bash
cd frontend/liam-erd
pnpm build
```

- [ ] **Step 9: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/
git commit -m "Add WoodsNode React Flow component with type-aware color palette"
```

---

### Task 7: Convert schema nodes to React Flow nodes and edges

**Files:**
- Modify: The file in erd-core that converts schema data to React Flow nodes/edges (find by grepping for where `nodes` and `edges` arrays are built from schema tables)

- [ ] **Step 1: Find the schema-to-ReactFlow conversion**

```bash
grep -r "useNodes\|setNodes\|addNode\|tableToNode\|buildNodes" frontend/liam-erd/packages/erd-core/src/ --include="*.ts" --include="*.tsx" -l
```

Read the file that converts schema `tables` into React Flow `Node[]` objects. This is where we add conversion of schema `nodes` to React Flow nodes + dependency edges.

- [ ] **Step 2: Add node conversion logic**

In the identified file, after the existing table→node conversion loop, add:

```typescript
// Convert woods nodes to React Flow nodes
if (schema.nodes) {
  for (const [id, woodsNode] of Object.entries(schema.nodes)) {
    reactFlowNodes.push({
      id: `woods-${id}`,
      type: 'woodsNode',
      position: { x: 0, y: 0 }, // ELK will position
      data: {
        name: woodsNode.name,
        type: woodsNode.type,
        members: woodsNode.members,
        meta: woodsNode.meta,
        dependencies: woodsNode.dependencies,
      },
    })

    // Convert dependencies to React Flow edges
    for (const dep of woodsNode.dependencies) {
      const targetId = dep.target_type === 'table' ? dep.target : `woods-${dep.target}`
      reactFlowEdges.push({
        id: `dep-${id}-${dep.target}-${dep.via}`,
        source: `woods-${id}`,
        target: targetId,
        type: 'dependency',
        data: { via: dep.via, sourceType: woodsNode.type },
        style: { strokeDasharray: '5,5' },
      })
    }
  }
}
```

- [ ] **Step 3: Verify build compiles**

```bash
cd frontend/liam-erd && pnpm build
```

- [ ] **Step 4: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/
git commit -m "Convert schema nodes and dependencies to React Flow nodes and edges"
```

---

### Task 8: Add toolbar layer toggles

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/erd/components/LayerToggle/`

- [ ] **Step 1: Find the existing toolbar**

```bash
grep -r "Controls\|Toolbar\|toolbar\|BottomBar\|bottomBar" frontend/liam-erd/packages/erd-core/src/ --include="*.tsx" -l
```

Read the toolbar component to understand:
- Where the "Key Only" dropdown lives
- What component library is used (Radix? custom?)
- How state is managed (React context? zustand? URL params?)

- [ ] **Step 2: Create layer toggle state**

Create a React context or zustand store (match existing pattern) for layer visibility:

```typescript
// LayerToggle/useLayerState.ts
import { useState, useCallback } from 'react'

export type NodeLayer = 'controllers' | 'jobs' | 'services' | 'mailers'
export type EdgeLayer = 'data' | 'dependency'

interface LayerState {
  nodeLayers: Record<NodeLayer, boolean>
  edgeLayers: Record<EdgeLayer, boolean>
  focusedNode: string | null
  toggleNodeLayer: (layer: NodeLayer) => void
  toggleEdgeLayer: (layer: EdgeLayer) => void
  setFocusedNode: (nodeId: string | null) => void
}

export function useLayerState(): LayerState {
  const [nodeLayers, setNodeLayers] = useState<Record<NodeLayer, boolean>>({
    controllers: false,
    jobs: false,
    services: false,
    mailers: false,
  })

  const [edgeLayers, setEdgeLayers] = useState<Record<EdgeLayer, boolean>>({
    data: true,
    dependency: true,
  })

  const [focusedNode, setFocusedNode] = useState<string | null>(null)

  const toggleNodeLayer = useCallback((layer: NodeLayer) => {
    setNodeLayers((prev) => ({ ...prev, [layer]: !prev[layer] }))
  }, [])

  const toggleEdgeLayer = useCallback((layer: EdgeLayer) => {
    setEdgeLayers((prev) => ({ ...prev, [layer]: !prev[layer] }))
  }, [])

  return { nodeLayers, edgeLayers, focusedNode, toggleNodeLayer, toggleEdgeLayer, setFocusedNode }
}
```

- [ ] **Step 3: Create the LayerToggle dropdown component**

Create `LayerToggle/LayerToggleDropdown.tsx` — a popover/dropdown that sits in the toolbar, containing:

- Checkboxes for each node layer (Controllers, Jobs, Services, Mailers)
- Checkboxes for each edge layer (Data edges, Dependency edges)
- Color dots next to each node layer matching the WCAG palette

Use the same UI component pattern as the existing "Key Only" dropdown (likely Radix Popover or similar). Study the existing dropdown and match its visual style.

- [ ] **Step 4: Wire layer state to node/edge filtering**

In the component that renders `<ReactFlow>`, apply filtering:

```typescript
// Filter nodes based on active layers
const visibleNodes = allNodes.filter((node) => {
  if (node.type === 'woodsNode') {
    const woodsType = (node.data as WoodsNodeData).type
    const layerKey = `${woodsType}s` as NodeLayer
    return layerState.nodeLayers[layerKey]
  }
  return true // table nodes always visible
})

// Filter edges based on layers
const visibleEdges = allEdges.filter((edge) => {
  if (edge.type === 'dependency') {
    return layerState.edgeLayers.dependency
  }
  // FK/relationship edges
  return layerState.edgeLayers.data
})
```

- [ ] **Step 5: Insert LayerToggleDropdown into toolbar**

Find where the bottom toolbar renders and add the LayerToggle next to existing controls. Match the visual style of the "Key Only" button.

- [ ] **Step 6: Verify build**

```bash
cd frontend/liam-erd && pnpm build
```

- [ ] **Step 7: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/
git commit -m "Add toolbar layer toggles for node types and edge categories"
```

---

### Task 9: Implement sidebar focus mode

**Files:**
- Modify: Sidebar component in erd-core

- [ ] **Step 1: Find the sidebar component**

```bash
grep -r "TableList\|sidebar\|SidePanel\|LeftPanel" frontend/liam-erd/packages/erd-core/src/ --include="*.tsx" -l
```

Read the sidebar that lists tables. Understand how items are rendered and if there's already a click handler.

- [ ] **Step 2: Add focus button to sidebar items**

For each item in the sidebar list (both tables and nodes), add a focus icon/button. When clicked, it calls `setFocusedNode(nodeId)` from the layer state.

The focus button should be a small icon (e.g., crosshair or target icon) that appears on hover of the sidebar row.

- [ ] **Step 3: Add non-model nodes to sidebar**

Below the table list (or in a tabbed view if the sidebar uses tabs), add sections for each active node layer:

```tsx
{layerState.nodeLayers.controllers && (
  <NodeSection title="Controllers" nodes={controllerNodes} onFocus={setFocusedNode} />
)}
{layerState.nodeLayers.jobs && (
  <NodeSection title="Jobs" nodes={jobNodes} onFocus={setFocusedNode} />
)}
{/* ... services, mailers */}
```

Each section lists nodes of that type with a focus button.

- [ ] **Step 4: Implement focus filtering**

When `focusedNode` is set (non-null), override the visible nodes filter:

```typescript
// If a node is focused, show only it and its connected nodes
if (layerState.focusedNode) {
  const focusedId = layerState.focusedNode
  const connectedIds = new Set<string>()
  connectedIds.add(focusedId)

  // Find all edges touching the focused node
  allEdges.forEach((edge) => {
    if (edge.source === focusedId) connectedIds.add(edge.target)
    if (edge.target === focusedId) connectedIds.add(edge.source)
  })

  visibleNodes = allNodes.filter((node) => {
    if (!connectedIds.has(node.id)) return false
    // Still respect layer toggles for non-model nodes
    if (node.type === 'woodsNode') {
      const woodsType = (node.data as WoodsNodeData).type
      const layerKey = `${woodsType}s` as NodeLayer
      return layerState.nodeLayers[layerKey]
    }
    return true
  })

  visibleEdges = allEdges.filter((edge) =>
    connectedIds.has(edge.source) && connectedIds.has(edge.target)
  )
}
```

- [ ] **Step 5: Add "Exit Focus" button**

When focus mode is active, render a floating button or breadcrumb at the top of the canvas:

```tsx
{layerState.focusedNode && (
  <div style={{
    position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)',
    zIndex: 10, background: '#2d2d3e', padding: '6px 16px', borderRadius: '6px',
    display: 'flex', alignItems: 'center', gap: '8px', fontSize: '13px', color: '#cbd5e1',
  }}>
    <span>Focused: {layerState.focusedNode}</span>
    <button onClick={() => setFocusedNode(null)} style={{
      background: 'none', border: '1px solid #475569', borderRadius: '4px',
      color: '#94a3b8', padding: '2px 8px', cursor: 'pointer', fontSize: '12px',
    }}>
      Exit Focus
    </button>
  </div>
)}
```

- [ ] **Step 6: Verify build**

```bash
cd frontend/liam-erd && pnpm build
```

- [ ] **Step 7: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/
git commit -m "Add sidebar focus mode with connected-node filtering"
```

---

### Task 10: Implement hover vs. selection color distinction

**Files:**
- Modify: Node components and edge rendering in erd-core

- [ ] **Step 1: Find existing hover/selection logic**

```bash
grep -r "selected\|highlight\|active.*node\|onNodeClick\|hovered" frontend/liam-erd/packages/erd-core/src/ --include="*.tsx" -l
```

Understand how the existing TableNode highlights on click and hover. Typically this involves:
- React Flow's built-in `selected` prop on nodes
- A custom store/context for "highlighted" nodes (connected to selected)
- CSS classes or inline styles for the green glow effect seen in the screenshots

- [ ] **Step 2: Separate selected vs. hovered styling**

Modify the highlight logic so that:
- **Selected node** (clicked): uses the node type's color for border glow + connected edge highlighting
  - Table nodes: existing green
  - WoodsNodes: their type color from `WOODS_NODE_COLORS`
- **Hovered node** (mouseover): uses the neutral hover accent (`#e2e8f0` / `HOVER_ACCENT`) for border glow + connected edge highlighting

This may involve:
- Adding an `onNodeMouseEnter` / `onNodeMouseLeave` handler to track hovered node ID
- Passing `hoveredNodeId` vs `selectedNodeId` to edge rendering
- Edges connected to selected node get the node's type color
- Edges connected to hovered (but not selected) node get the hover accent color

- [ ] **Step 3: Apply to WoodsNode component**

Update `WoodsNode.tsx` to accept `selected` and `hovered` state and apply the correct border color:

```typescript
const borderColor = selected
  ? colors.border
  : hovered
    ? HOVER_ACCENT
    : `${colors.border}40` // dimmed default
```

- [ ] **Step 4: Apply to existing TableNode**

Update the existing TableNode to use the hover accent for hover state instead of the same green as selection. This ensures consistent behavior across all node types.

- [ ] **Step 5: Verify build**

```bash
cd frontend/liam-erd && pnpm build
```

- [ ] **Step 6: Commit**

```bash
git add frontend/liam-erd/packages/erd-core/src/
git commit -m "Distinguish hover vs selection with separate color treatments"
```

---

### Task 11: Update build script and rebuild vendor assets

**Files:**
- Modify: `scripts/build-liam-erd.sh`
- Modify: `vendor/assets/liam-erd/` (rebuilt)

- [ ] **Step 1: Update build script**

Replace `scripts/build-liam-erd.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Build Liam ERD frontend assets from the local fork.
#
# Prerequisites: Node.js >= 18, pnpm >= 10
#
# Usage: ./scripts/build-liam-erd.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$ROOT_DIR/frontend/liam-erd"
VENDOR_DIR="$ROOT_DIR/vendor/assets/liam-erd"

if [ ! -d "$FRONTEND_DIR" ]; then
  echo "ERROR: frontend/liam-erd/ not found. Run from the woods-erd repo root."
  exit 1
fi

cd "$FRONTEND_DIR"

echo "==> Installing dependencies..."
pnpm install --frozen-lockfile 2>/dev/null || pnpm install

echo "==> Building CLI frontend..."
export VITE_CLI_VERSION_VERSION="woods-embedded-phase2"
export VITE_CLI_VERSION_GIT_HASH="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
export VITE_CLI_VERSION_ENV_NAME="woods"
export VITE_CLI_VERSION_IS_RELEASED_GIT_HASH="0"
export VITE_CLI_VERSION_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

pnpm build

echo "==> Copying built assets to $VENDOR_DIR..."
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
cp -r packages/cli/dist-cli/html/* "$VENDOR_DIR/"

# Remove schema.json and serve.json if present (we generate schema dynamically)
rm -f "$VENDOR_DIR/schema.json" "$VENDOR_DIR/serve.json"

echo "==> Done! Assets vendored at $VENDOR_DIR"
ls -lah "$VENDOR_DIR/"
```

- [ ] **Step 2: Run the build**

```bash
./scripts/build-liam-erd.sh
```

Verify the build succeeds and `vendor/assets/liam-erd/` is populated.

- [ ] **Step 3: Verify the ERD still loads**

If a Rails host app is available, restart the server and visit `/woods/erd`. The table-only view should look identical to Phase 1. If no host app is available, verify the vendored `index.html` references the same entry point structure.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-liam-erd.sh vendor/assets/liam-erd/
git commit -m "Update build script for local fork, rebuild vendor assets"
```

---

### Task 12: Integration validation and cleanup

**Files:**
- No new files — validation and final adjustments

- [ ] **Step 1: Run the full Ruby test suite**

```bash
bundle exec rake spec --format progress --format json --out tmp/test_results.json
```

Verify all specs pass, including the new configuration and schema generator tests.

- [ ] **Step 2: Run RuboCop**

```bash
bundle exec rubocop lib/woods/erd/ spec/erd/ lib/woods.rb spec/configuration_spec.rb
```

Fix any lint violations.

- [ ] **Step 3: Test with real extraction data (if host app available)**

In the host Rails app:
1. Configure `erd_layers: [:models, :controllers, :jobs, :services, :mailers]`
2. Restart the server
3. Visit `/woods/erd`
4. Verify:
   - Default view shows only model tables (same as Phase 1)
   - Toolbar has a layer toggle dropdown
   - Toggling "Controllers" adds controller nodes with blue headers
   - Toggling "Jobs" adds job nodes with amber headers
   - Controller nodes show action names as members
   - Dependency edges (dashed) connect controllers to their model tables
   - Focus button on sidebar narrows view to one node + connections
   - Exit Focus returns to full view
   - Hiding data edges removes FK lines while keeping model nodes
   - Hovering a node uses a different color than the selected node

- [ ] **Step 4: Measure schema.json payload size**

With all layers enabled, check the schema.json size:

```bash
curl -s http://localhost:3000/woods/erd/schema.json | wc -c
```

Note the size for documentation. If it exceeds 2MB, consider whether pagination or lazy loading is needed (unlikely for Tier 1 only).

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "Phase 2 integration validation: lint fixes and adjustments"
```

---

## Execution Notes

- **Tasks 1-3** are Ruby-only and can be done without Node.js.
- **Task 4** (fork setup) is the highest-risk task — if the shallow fork doesn't build cleanly, it may require copying additional packages or adjusting dependency resolution. Budget extra time here.
- **Tasks 5-10** are frontend work and depend on Task 4 completing successfully.
- **Task 11** rebuilds vendor assets and should be done after all frontend changes.
- **Task 12** is validation — run it last.
- Tasks 5-6 can potentially run in parallel (schema types + WoodsNode component) since they touch different packages.
- Tasks 8-10 (toolbar, focus, hover) are independent features and could be parallelized if multiple agents are available.
