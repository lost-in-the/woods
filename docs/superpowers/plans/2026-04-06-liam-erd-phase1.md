# Liam ERD Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve an interactive database ERD at `/woods/erd` using vendored Liam ERD assets and schema JSON generated from Woods' extracted model units.

**Architecture:** Rack middleware reads extracted model units from `output_dir`, transforms them to Liam's `schema.json` format (tables, columns, indexes, constraints), caches the result, and serves it alongside pre-built Liam SPA static assets. Configuration follows the existing `console_mcp_enabled` pattern via Railtie.

**Tech Stack:** Ruby/Rack (middleware), Liam ERD (vendored React SPA), Woods extractors (data source)

**Spec:** `docs/superpowers/specs/2026-04-06-liam-erd-design.md`
**Decisions:** `docs/superpowers/specs/2026-04-06-liam-erd-decisions.md`

---

### Task 1: Add ERD configuration options

**Files:**
- Modify: `lib/woods.rb:38-80`
- Test: `spec/configuration_spec.rb`

- [ ] **Step 1: Write failing tests for erd_enabled and erd_path defaults**

In `spec/configuration_spec.rb`, add inside the `describe 'default values'` block:

```ruby
it 'sets erd_enabled to false' do
  expect(config.erd_enabled).to eq(false)
end

it 'sets erd_path to /woods/erd' do
  expect(config.erd_path).to eq('/woods/erd')
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/configuration_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: 2 failures — `NoMethodError: undefined method 'erd_enabled'` and `'erd_path'`

- [ ] **Step 3: Add erd_enabled and erd_path to Configuration**

In `lib/woods.rb`, add `erd_enabled` and `erd_path` to the `attr_accessor` line (line 39):

```ruby
attr_accessor :embedding_model, :include_framework_sources, :gem_configs,
              :vector_store, :metadata_store, :graph_store, :embedding_provider, :log_level,
              :vector_store_options, :metadata_store_options, :embedding_options,
              :concurrent_extraction, :precompute_flows, :enable_snapshots,
              :session_tracer_enabled, :session_store, :session_id_proc, :session_exclude_paths,
              :console_mcp_enabled, :console_mcp_path, :console_redacted_columns,
              :notion_api_token, :notion_database_ids,
              :unblocked_api_token, :unblocked_collection_id, :unblocked_repo_url,
              :cache_store, :cache_options,
              :erd_enabled, :erd_path
```

In the `initialize` method, add after the `@cache_options` line (line 79):

```ruby
@erd_enabled = false
@erd_path = '/woods/erd'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/configuration_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/woods.rb spec/configuration_spec.rb
git commit -m "Add erd_enabled and erd_path configuration options"
```

---

### Task 2: Add indexes and foreign_keys to model extractor metadata

**Files:**
- Modify: `lib/woods/extractors/model_extractor.rb:354-361`
- Test: `spec/extractors/model_extractor_spec.rb`

- [ ] **Step 1: Write failing tests for indexes metadata**

In `spec/extractors/model_extractor_spec.rb`, add a new describe block:

```ruby
describe '#extract_metadata indexes and foreign_keys' do
  let(:model) do
    model = double('Model')
    allow(model).to receive_messages(
      table_name: 'posts',
      primary_key: 'id',
      table_exists?: true,
      reflect_on_all_associations: [],
      inheritance_column: 'type',
      superclass: double(name: 'ApplicationRecord'),
      methods: [],
      instance_methods: [],
      column_names: %w[id title],
      columns: [
        double(name: 'id', sql_type: 'bigint', null: false, default: nil),
        double(name: 'title', sql_type: 'varchar(255)', null: true, default: nil)
      ],
      abstract_class?: false,
      name: 'Post'
    )
    allow(model).to receive(:_validators).and_return({})
    allow(model).to receive(:_callbacks).and_return([])
    model
  end

  let(:connection) { double('Connection') }

  before do
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
  end

  it 'extracts structured index metadata' do
    index = double(name: 'index_posts_on_title', unique: false, columns: ['title'])
    allow(connection).to receive(:indexes).with('posts').and_return([index])
    allow(connection).to receive(:foreign_keys).with('posts').and_return([])

    metadata = extractor.send(:extract_metadata, model)

    expect(metadata[:indexes]).to eq([
      { 'name' => 'index_posts_on_title', 'unique' => false, 'columns' => ['title'] }
    ])
  end

  it 'extracts structured foreign_key metadata' do
    fk = double(
      from_table: 'posts', to_table: 'users', column: 'user_id',
      primary_key: 'id', name: 'fk_posts_user_id',
      on_delete: :cascade, on_update: nil
    )
    allow(connection).to receive(:indexes).with('posts').and_return([])
    allow(connection).to receive(:foreign_keys).with('posts').and_return([fk])

    metadata = extractor.send(:extract_metadata, model)

    expect(metadata[:foreign_keys]).to eq([
      {
        'from_table' => 'posts', 'to_table' => 'users', 'column' => 'user_id',
        'primary_key' => 'id', 'name' => 'fk_posts_user_id',
        'on_delete' => :cascade, 'on_update' => nil
      }
    ])
  end

  it 'returns empty arrays when table does not exist' do
    allow(model).to receive(:table_exists?).and_return(false)

    metadata = extractor.send(:extract_metadata, model)

    expect(metadata[:indexes]).to eq([])
    expect(metadata[:foreign_keys]).to eq([])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/extractors/model_extractor_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: Failures — `metadata[:indexes]` and `metadata[:foreign_keys]` are nil

- [ ] **Step 3: Add indexes and foreign_keys to extract_metadata**

In `lib/woods/extractors/model_extractor.rb`, after the `columns:` block (after line 360, before `# ActiveStorage / ActionText`), add:

```ruby
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/extractors/model_extractor_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/woods/extractors/model_extractor.rb spec/extractors/model_extractor_spec.rb
git commit -m "Add structured indexes and foreign_keys to model extractor metadata"
```

---

### Task 3: Build SchemaGenerator

**Files:**
- Create: `lib/woods/erd/schema_generator.rb`
- Test: `spec/erd/schema_generator_spec.rb`

- [ ] **Step 1: Write failing tests for basic table generation**

Create `spec/erd/schema_generator_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'woods/erd/schema_generator'

RSpec.describe Woods::Erd::SchemaGenerator do
  let(:output_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(output_dir) }

  def write_model_unit(identifier, metadata)
    models_dir = File.join(output_dir, 'models')
    FileUtils.mkdir_p(models_dir)

    unit = {
      'type' => 'model',
      'identifier' => identifier,
      'metadata' => metadata
    }

    digest = Digest::SHA256.hexdigest(identifier)[0, 8]
    filename = "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}_#{digest}.json"
    File.write(File.join(models_dir, filename), JSON.generate(unit))

    # Write _index.json
    index_path = File.join(models_dir, '_index.json')
    existing = File.exist?(index_path) ? JSON.parse(File.read(index_path)) : []
    existing << { 'identifier' => identifier, 'file' => filename }
    File.write(index_path, JSON.generate(existing))
  end

  describe '#generate' do
    it 'generates a table with columns' do
      write_model_unit('Post', {
        'table_name' => 'posts',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
          { 'name' => 'title', 'type' => 'varchar(255)', 'null' => false, 'default' => nil },
          { 'name' => 'body', 'type' => 'text', 'null' => true, 'default' => nil }
        ],
        'associations' => [],
        'indexes' => [],
        'foreign_keys' => [],
        'enums' => {}
      })

      schema = described_class.new(output_dir).generate

      expect(schema['tables']).to have_key('posts')
      table = schema['tables']['posts']
      expect(table['name']).to eq('posts')
      expect(table['columns']['id']['notNull']).to eq(true)
      expect(table['columns']['title']['type']).to eq('varchar(255)')
      expect(table['columns']['body']['notNull']).to eq(false)
    end

    it 'generates primary key constraints' do
      write_model_unit('Post', {
        'table_name' => 'posts',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }
        ],
        'associations' => [],
        'indexes' => [],
        'foreign_keys' => [],
        'enums' => {}
      })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['posts']['constraints']

      expect(constraints).to have_key('posts_pkey')
      pk = constraints['posts_pkey']
      expect(pk['type']).to eq('PRIMARY KEY')
      expect(pk['columnNames']).to eq(['id'])
    end

    it 'generates foreign key constraints from foreign_keys metadata' do
      write_model_unit('Post', {
        'table_name' => 'posts',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
          { 'name' => 'user_id', 'type' => 'bigint', 'null' => false, 'default' => nil }
        ],
        'associations' => [
          { 'name' => 'user', 'type' => 'belongs_to', 'target' => 'User', 'foreign_key' => 'user_id', 'polymorphic' => false }
        ],
        'foreign_keys' => [
          { 'from_table' => 'posts', 'to_table' => 'users', 'column' => 'user_id', 'primary_key' => 'id', 'name' => 'fk_rails_user', 'on_delete' => nil, 'on_update' => nil }
        ],
        'indexes' => [],
        'enums' => {}
      })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['posts']['constraints']

      expect(constraints).to have_key('fk_rails_user')
      fk = constraints['fk_rails_user']
      expect(fk['type']).to eq('FOREIGN KEY')
      expect(fk['columnNames']).to eq(['user_id'])
      expect(fk['targetTableName']).to eq('users')
      expect(fk['targetColumnNames']).to eq(['id'])
    end

    it 'falls back to association-derived FKs when foreign_keys metadata absent' do
      write_model_unit('User', {
        'table_name' => 'users',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
        'associations' => [],
        'indexes' => [],
        'foreign_keys' => [],
        'enums' => {}
      })

      write_model_unit('Post', {
        'table_name' => 'posts',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
          { 'name' => 'user_id', 'type' => 'bigint', 'null' => false, 'default' => nil }
        ],
        'associations' => [
          { 'name' => 'user', 'type' => 'belongs_to', 'target' => 'User', 'foreign_key' => 'user_id', 'polymorphic' => false }
        ],
        'indexes' => [],
        'enums' => {}
        # Note: no 'foreign_keys' key at all
      })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['posts']['constraints']

      fk_key = 'fk_posts_user_id'
      expect(constraints).to have_key(fk_key)
      expect(constraints[fk_key]['targetTableName']).to eq('users')
    end

    it 'skips polymorphic associations in FK generation' do
      write_model_unit('Comment', {
        'table_name' => 'comments',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
          { 'name' => 'commentable_id', 'type' => 'bigint', 'null' => false, 'default' => nil },
          { 'name' => 'commentable_type', 'type' => 'varchar(255)', 'null' => false, 'default' => nil }
        ],
        'associations' => [
          { 'name' => 'commentable', 'type' => 'belongs_to', 'target' => 'Comment', 'foreign_key' => 'commentable_id', 'polymorphic' => true }
        ],
        'foreign_keys' => [],
        'indexes' => [],
        'enums' => {}
      })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['comments']['constraints']

      fk_constraints = constraints.values.select { |c| c['type'] == 'FOREIGN KEY' }
      expect(fk_constraints).to be_empty
    end

    it 'generates indexes' do
      write_model_unit('Post', {
        'table_name' => 'posts',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
          { 'name' => 'slug', 'type' => 'varchar(255)', 'null' => false, 'default' => nil }
        ],
        'associations' => [],
        'indexes' => [
          { 'name' => 'index_posts_on_slug', 'unique' => true, 'columns' => ['slug'] }
        ],
        'foreign_keys' => [],
        'enums' => {}
      })

      schema = described_class.new(output_dir).generate
      indexes = schema['tables']['posts']['indexes']

      expect(indexes).to have_key('index_posts_on_slug')
      expect(indexes['index_posts_on_slug']['unique']).to eq(true)
      expect(indexes['index_posts_on_slug']['columns']).to eq(['slug'])
    end

    it 'deduplicates STI models sharing a table' do
      write_model_unit('Vehicle', {
        'table_name' => 'vehicles',
        'table_exists' => true,
        'primary_key' => 'id',
        'is_sti_base' => true,
        'is_sti_child' => false,
        'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
        'associations' => [],
        'indexes' => [],
        'foreign_keys' => [],
        'enums' => {}
      })

      write_model_unit('Car', {
        'table_name' => 'vehicles',
        'table_exists' => true,
        'primary_key' => 'id',
        'is_sti_base' => false,
        'is_sti_child' => true,
        'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
        'associations' => [],
        'indexes' => [],
        'foreign_keys' => [],
        'enums' => {}
      })

      schema = described_class.new(output_dir).generate

      expect(schema['tables'].keys).to eq(['vehicles'])
    end

    it 'skips models where table_exists is false' do
      write_model_unit('Ghost', {
        'table_name' => 'ghosts',
        'table_exists' => false,
        'primary_key' => 'id',
        'columns' => [],
        'associations' => [],
        'indexes' => [],
        'foreign_keys' => [],
        'enums' => {}
      })

      schema = described_class.new(output_dir).generate

      expect(schema['tables']).to be_empty
    end

    it 'returns valid schema structure with enums and extensions' do
      write_model_unit('Post', {
        'table_name' => 'posts',
        'table_exists' => true,
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
        'associations' => [],
        'indexes' => [],
        'foreign_keys' => [],
        'enums' => { 'status' => { 'draft' => 0, 'published' => 1 } }
      })

      schema = described_class.new(output_dir).generate

      expect(schema).to have_key('tables')
      expect(schema).to have_key('enums')
      expect(schema).to have_key('extensions')
    end

    it 'raises an error when output directory has no models dir' do
      expect {
        described_class.new(output_dir).generate
      }.to raise_error(Woods::Error, /no extracted model data/i)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/erd/schema_generator_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: `LoadError: cannot load such file -- woods/erd/schema_generator`

- [ ] **Step 3: Implement SchemaGenerator**

Create `lib/woods/erd/schema_generator.rb`:

```ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

module Woods
  module Erd
    # Transforms Woods extracted model units into Liam ERD's schema.json format.
    #
    # Reads model unit JSON files from the extraction output directory and
    # produces a schema conforming to Liam's schemaSchema: tables with columns,
    # indexes, and constraints (primary keys, foreign keys).
    #
    # @example
    #   generator = SchemaGenerator.new("/app/tmp/woods")
    #   schema = generator.generate
    #   # => { "tables" => { "posts" => { ... } }, "enums" => {}, "extensions" => {} }
    #
    class SchemaGenerator
      # @param output_dir [String, Pathname] Path to Woods extraction output directory
      def initialize(output_dir)
        @output_dir = Pathname.new(output_dir)
      end

      # Generate a Liam-compatible schema hash from extracted model units.
      #
      # @return [Hash] Schema with tables, enums, and extensions keys
      # @raise [Woods::Error] if no extracted model data is found
      def generate
        models_dir = @output_dir.join('models')
        raise Woods::Error, 'No extracted model data found in output directory' unless models_dir.directory?

        units = load_model_units(models_dir)
        tables = build_tables(units)
        enums = build_enums(units)

        { 'tables' => tables, 'enums' => enums, 'extensions' => {} }
      end

      private

      # Load all model unit JSON files from the models directory.
      #
      # @param models_dir [Pathname] Path to the models subdirectory
      # @return [Array<Hash>] Parsed unit data
      def load_model_units(models_dir)
        models_dir.children
                  .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                  .map { |f| JSON.parse(f.read) }
      end

      # Build Liam tables hash, deduplicating STI models.
      #
      # @param units [Array<Hash>] Model unit data
      # @return [Hash] Tables keyed by table_name
      def build_tables(units)
        tables = {}

        units.each do |unit|
          meta = unit['metadata'] || {}
          table_name = meta['table_name']
          next if table_name.nil?
          next unless meta['table_exists']
          next if tables.key?(table_name) # STI dedup: first model wins (base class)

          tables[table_name] = build_table(table_name, meta, units)
        end

        tables
      end

      # Build a single Liam table from model metadata.
      #
      # @param table_name [String] Database table name
      # @param meta [Hash] Model metadata
      # @param all_units [Array<Hash>] All model units (for FK target resolution)
      # @return [Hash] Liam table structure
      def build_table(table_name, meta, all_units)
        {
          'name' => table_name,
          'comment' => nil,
          'columns' => build_columns(meta['columns'] || []),
          'indexes' => build_indexes(meta['indexes'] || []),
          'constraints' => build_constraints(table_name, meta, all_units)
        }
      end

      # Convert Woods columns to Liam column records.
      #
      # @param columns [Array<Hash>] Woods column data
      # @return [Hash] Columns keyed by name
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

      # Convert Woods indexes to Liam index records.
      #
      # @param indexes [Array<Hash>] Woods index data
      # @return [Hash] Indexes keyed by name
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

      # Build all constraints (primary key + foreign keys) for a table.
      #
      # @param table_name [String] Database table name
      # @param meta [Hash] Model metadata
      # @param all_units [Array<Hash>] All model units
      # @return [Hash] Constraints keyed by name
      def build_constraints(table_name, meta, all_units)
        constraints = {}

        # Primary key
        pk = meta['primary_key']
        if pk
          pk_name = "#{table_name}_pkey"
          constraints[pk_name] = {
            'type' => 'PRIMARY KEY',
            'name' => pk_name,
            'columnNames' => Array(pk)
          }
        end

        # Foreign keys from structured metadata (preferred)
        if meta.key?('foreign_keys') && !meta['foreign_keys'].empty?
          build_foreign_keys_from_metadata(meta['foreign_keys'], constraints)
        else
          # Fallback: derive from belongs_to associations
          build_foreign_keys_from_associations(table_name, meta, all_units, constraints)
        end

        constraints
      end

      # Build FK constraints from structured foreign_keys metadata.
      #
      # @param foreign_keys [Array<Hash>] Foreign key metadata
      # @param constraints [Hash] Constraints hash to populate
      # @return [void]
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

      # Build FK constraints from belongs_to associations (fallback).
      #
      # @param table_name [String] Source table name
      # @param meta [Hash] Model metadata
      # @param all_units [Array<Hash>] All model units for target resolution
      # @param constraints [Hash] Constraints hash to populate
      # @return [void]
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

      # Build a lookup from model identifier to table_name.
      #
      # @param units [Array<Hash>] All model units
      # @return [Hash] Model name => table name
      def build_table_lookup(units)
        units.each_with_object({}) do |unit, lookup|
          meta = unit['metadata'] || {}
          next unless meta['table_exists']

          lookup[unit['identifier']] = meta['table_name']
        end
      end

      # Build Liam enums from model enum definitions.
      #
      # @param units [Array<Hash>] Model unit data
      # @return [Hash] Enums keyed by name
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

      # Map Rails FK action symbols to Liam constraint action strings.
      #
      # @param action [Symbol, String, nil] Rails FK action
      # @return [String] Liam constraint action
      def map_fk_action(action)
        case action.to_s
        when 'cascade' then 'CASCADE'
        when 'restrict' then 'RESTRICT'
        when 'nullify', 'set_null' then 'SET_NULL'
        when 'set_default' then 'SET_DEFAULT'
        else 'NO_ACTION'
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/erd/schema_generator_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All pass

- [ ] **Step 5: Run rubocop on new file**

Run: `bundle exec rubocop lib/woods/erd/schema_generator.rb spec/erd/schema_generator_spec.rb -a`
Fix any offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/woods/erd/schema_generator.rb spec/erd/schema_generator_spec.rb
git commit -m "Add SchemaGenerator to transform Woods models to Liam schema format"
```

---

### Task 4: Build Rack Middleware

**Files:**
- Create: `lib/woods/erd/rack_middleware.rb`
- Test: `spec/erd/rack_middleware_spec.rb`

- [ ] **Step 1: Write failing tests for middleware routing**

Create `spec/erd/rack_middleware_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'woods/erd/rack_middleware'
require 'rack'

RSpec.describe Woods::Erd::RackMiddleware do
  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['inner app']] } }
  let(:output_dir) { Dir.mktmpdir }
  let(:assets_dir) { Dir.mktmpdir }
  let(:middleware) { described_class.new(inner_app, path: '/woods/erd', output_dir: output_dir, assets_dir: assets_dir) }

  after do
    FileUtils.remove_entry(output_dir)
    FileUtils.remove_entry(assets_dir)
  end

  def request(path, method: 'GET')
    env = Rack::MockRequest.env_for(path, method: method)
    middleware.call(env)
  end

  describe 'pass-through' do
    it 'passes non-matching requests to the inner app' do
      status, _headers, body = request('/other/path')

      expect(status).to eq(200)
      expect(body).to eq(['inner app'])
    end
  end

  describe 'index.html serving' do
    before do
      File.write(File.join(assets_dir, 'index.html'), '<html>ERD</html>')
    end

    it 'serves index.html at the base path' do
      status, headers, body = request('/woods/erd')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/html')
      expect(body.join).to include('ERD')
    end

    it 'serves index.html at the base path with trailing slash' do
      status, headers, _body = request('/woods/erd/')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/html')
    end
  end

  describe 'static asset serving' do
    before do
      FileUtils.mkdir_p(File.join(assets_dir, 'assets'))
      File.write(File.join(assets_dir, 'assets', 'main.js'), 'console.log("erd")')
      File.write(File.join(assets_dir, 'assets', 'style.css'), 'body {}')
    end

    it 'serves JavaScript files with correct content type' do
      status, headers, body = request('/woods/erd/assets/main.js')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/javascript')
      expect(body.join).to include('console.log')
    end

    it 'serves CSS files with correct content type' do
      status, headers, _body = request('/woods/erd/assets/style.css')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/css')
    end

    it 'returns 404 for missing assets' do
      status, _headers, _body = request('/woods/erd/assets/missing.js')

      expect(status).to eq(404)
    end
  end

  describe 'schema.json serving' do
    before do
      models_dir = File.join(output_dir, 'models')
      FileUtils.mkdir_p(models_dir)

      unit = {
        'type' => 'model',
        'identifier' => 'Post',
        'metadata' => {
          'table_name' => 'posts',
          'table_exists' => true,
          'primary_key' => 'id',
          'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
          'associations' => [],
          'indexes' => [],
          'foreign_keys' => [],
          'enums' => {}
        }
      }

      digest = Digest::SHA256.hexdigest('Post')[0, 8]
      File.write(File.join(models_dir, "Post_#{digest}.json"), JSON.generate(unit))
      File.write(File.join(models_dir, '_index.json'), JSON.generate([{ 'identifier' => 'Post', 'file' => "Post_#{digest}.json" }]))
    end

    it 'serves generated schema.json' do
      status, headers, body = request('/woods/erd/schema.json')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/json')

      schema = JSON.parse(body.join)
      expect(schema['tables']).to have_key('posts')
    end

    it 'caches schema.json after first request' do
      request('/woods/erd/schema.json')

      # Delete the source files — cached response should still work
      FileUtils.rm_rf(File.join(output_dir, 'models'))

      status, _headers, body = request('/woods/erd/schema.json')

      expect(status).to eq(200)
      schema = JSON.parse(body.join)
      expect(schema['tables']).to have_key('posts')
    end
  end

  describe 'error handling' do
    it 'returns error JSON when no extraction data exists' do
      status, headers, body = request('/woods/erd/schema.json')

      expect(status).to eq(503)
      expect(headers['content-type']).to eq('application/json')

      error = JSON.parse(body.join)
      expect(error['error']).to match(/extract/i)
    end
  end

  describe 'path traversal protection' do
    before do
      File.write(File.join(assets_dir, 'index.html'), '<html>ERD</html>')
    end

    it 'rejects path traversal attempts' do
      status, _headers, _body = request('/woods/erd/../../../etc/passwd')

      expect(status).to eq(404)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/erd/rack_middleware_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: `LoadError: cannot load such file -- woods/erd/rack_middleware`

- [ ] **Step 3: Implement RackMiddleware**

Create `lib/woods/erd/rack_middleware.rb`:

```ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'schema_generator'

module Woods
  module Erd
    # Rack middleware that serves the Liam ERD visualization.
    #
    # Intercepts requests at a configurable path and serves:
    # - Pre-built Liam SPA static assets (HTML, JS, CSS)
    # - Dynamically generated schema.json from Woods extracted model units
    #
    # Schema JSON is generated on first request and cached in memory.
    #
    # @example In config/application.rb via Railtie:
    #   # Automatically inserted when config.erd_enabled = true
    #   config.middleware.use Woods::Erd::RackMiddleware, path: '/woods/erd'
    #
    class RackMiddleware
      CONTENT_TYPES = {
        '.html' => 'text/html',
        '.js' => 'application/javascript',
        '.css' => 'text/css',
        '.json' => 'application/json',
        '.svg' => 'image/svg+xml',
        '.png' => 'image/png',
        '.ico' => 'image/x-icon',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2'
      }.freeze

      # @param app [#call] The next Rack app in the middleware stack
      # @param path [String] URL path to mount the ERD (default: '/woods/erd')
      # @param output_dir [String, Pathname] Woods extraction output directory
      # @param assets_dir [String, Pathname, nil] Override for vendored assets location
      def initialize(app, path: '/woods/erd', output_dir: nil, assets_dir: nil)
        @app = app
        @path = path.chomp('/')
        @output_dir = output_dir&.to_s || default_output_dir
        @assets_dir = Pathname.new(assets_dir || default_assets_dir)
        @cached_schema = nil
      end

      # Rack interface — intercepts requests at the configured path.
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response triple
      def call(env)
        request_path = env['PATH_INFO']

        return @app.call(env) unless request_path.start_with?(@path)

        relative_path = request_path[@path.length..] || ''
        relative_path = '/' if relative_path.empty?

        serve(relative_path)
      end

      private

      # Route a request to the appropriate handler.
      #
      # @param relative_path [String] Path relative to the mount point
      # @return [Array] Rack response triple
      def serve(relative_path)
        case relative_path
        when '/', '/index.html'
          serve_file('index.html')
        when '/schema.json'
          serve_schema
        else
          serve_file(relative_path.delete_prefix('/'))
        end
      end

      # Serve a static file from the assets directory.
      #
      # @param filename [String] Relative path within assets directory
      # @return [Array] Rack response triple
      def serve_file(filename)
        # Prevent path traversal
        file_path = @assets_dir.join(filename).cleanpath
        return not_found unless file_path.to_s.start_with?(@assets_dir.to_s)
        return not_found unless file_path.file?

        ext = file_path.extname
        content_type = CONTENT_TYPES[ext] || 'application/octet-stream'
        body = file_path.read

        [200, { 'content-type' => content_type, 'content-length' => body.bytesize.to_s }, [body]]
      end

      # Serve the generated schema JSON, caching after first generation.
      #
      # @return [Array] Rack response triple
      def serve_schema
        @cached_schema ||= generate_schema
        [200, { 'content-type' => 'application/json', 'content-length' => @cached_schema.bytesize.to_s }, [@cached_schema]]
      rescue Woods::Error => e
        error_json = JSON.generate({ 'error' => e.message })
        [503, { 'content-type' => 'application/json', 'content-length' => error_json.bytesize.to_s }, [error_json]]
      end

      # Generate schema JSON from extracted model units.
      #
      # @return [String] JSON string
      def generate_schema
        schema = SchemaGenerator.new(@output_dir).generate
        JSON.generate(schema)
      end

      # @return [Array] 404 response
      def not_found
        [404, { 'content-type' => 'text/plain', 'content-length' => '9' }, ['Not Found']]
      end

      # @return [String] Default output directory
      def default_output_dir
        if defined?(Rails) && Rails.root
          Rails.root.join('tmp/woods').to_s
        else
          'tmp/woods'
        end
      end

      # @return [String] Default vendored assets directory
      def default_assets_dir
        File.expand_path('../../../vendor/assets/liam-erd', __dir__)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/erd/rack_middleware_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All pass

- [ ] **Step 5: Run rubocop on new file**

Run: `bundle exec rubocop lib/woods/erd/rack_middleware.rb spec/erd/rack_middleware_spec.rb -a`
Fix any offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/woods/erd/rack_middleware.rb spec/erd/rack_middleware_spec.rb
git commit -m "Add ERD Rack middleware for serving Liam assets and schema.json"
```

---

### Task 5: Add Railtie initializer

**Files:**
- Modify: `lib/woods/railtie.rb`

- [ ] **Step 1: Add the woods.erd initializer**

In `lib/woods/railtie.rb`, add after the `woods.console_mcp` initializer block (after line 36, before the final `end`):

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

- [ ] **Step 2: Run full test suite to verify no regressions**

Run: `bundle exec rspec --format progress --format json --out tmp/test_results.json`
Expected: All pass (Railtie code doesn't execute in unit tests, so this is a regression check)

- [ ] **Step 3: Commit**

```bash
git add lib/woods/railtie.rb
git commit -m "Add woods.erd Railtie initializer to mount ERD middleware"
```

---

### Task 6: Update gemspec for vendored assets

**Files:**
- Modify: `woods.gemspec`

- [ ] **Step 1: Add vendor/assets to spec.files**

In `woods.gemspec`, update the `spec.files` block (line 32-39):

```ruby
  spec.files = Dir[
    'lib/**/*',
    'exe/*',
    'vendor/assets/liam-erd/**/*',
    'LICENSE.txt',
    'README.md',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'CODE_OF_CONDUCT.md'
  ]
```

- [ ] **Step 2: Commit**

```bash
git add woods.gemspec
git commit -m "Include vendored Liam ERD assets in gem package"
```

---

### Task 7: Build and vendor Liam ERD assets

**Files:**
- Create: `scripts/build-liam-erd.sh`
- Create: `vendor/assets/liam-erd/` (populated by script)

- [ ] **Step 1: Create the build script**

Create `scripts/build-liam-erd.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Build Liam ERD frontend assets for vendoring in the Woods gem.
#
# Prerequisites: Node.js >= 18, pnpm >= 10
#
# Usage: ./scripts/build-liam-erd.sh
#
# This clones the Liam ERD repository, builds the CLI frontend package,
# and copies the compiled assets to vendor/assets/liam-erd/.

LIAM_VERSION="v0.7.24"  # Pin to a specific release
LIAM_REPO="https://github.com/liam-hq/liam.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$ROOT_DIR/vendor/assets/liam-erd"
TEMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "==> Cloning Liam ERD at $LIAM_VERSION..."
git clone --depth 1 --branch "$LIAM_VERSION" "$LIAM_REPO" "$TEMP_DIR/liam" 2>/dev/null || {
  echo "Tag $LIAM_VERSION not found, cloning main and checking out..."
  git clone --depth 100 "$LIAM_REPO" "$TEMP_DIR/liam"
  cd "$TEMP_DIR/liam"
  git checkout "$LIAM_VERSION"
}

cd "$TEMP_DIR/liam"

echo "==> Installing dependencies..."
pnpm install --frozen-lockfile

echo "==> Building CLI frontend..."
export VITE_CLI_VERSION_VERSION="woods-embedded"
export VITE_CLI_VERSION_GIT_HASH="$(git rev-parse --short HEAD)"
export VITE_CLI_VERSION_ENV_NAME="woods"
export VITE_CLI_VERSION_IS_RELEASED_GIT_HASH="0"
export VITE_CLI_VERSION_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd frontend/packages/cli
pnpm build

echo "==> Copying built assets to $VENDOR_DIR..."
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
cp -r dist-cli/html/* "$VENDOR_DIR/"

# Remove schema.json if present (we generate it dynamically)
rm -f "$VENDOR_DIR/schema.json"

echo "==> Done! Assets vendored at $VENDOR_DIR"
echo "    Liam version: $LIAM_VERSION"
echo "    Git hash: $(git rev-parse --short HEAD)"
ls -lah "$VENDOR_DIR/"
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x scripts/build-liam-erd.sh`

- [ ] **Step 3: Run the build script**

Run: `./scripts/build-liam-erd.sh`
Expected: Assets built and copied to `vendor/assets/liam-erd/`. Output shows file listing.

Note: This requires Node.js and pnpm. If not available locally, the build can be done in a Docker container or CI environment. The critical output is the files in `vendor/assets/liam-erd/`.

- [ ] **Step 4: Verify vendored assets exist**

Run: `ls -la vendor/assets/liam-erd/` and `ls -la vendor/assets/liam-erd/assets/ 2>/dev/null`
Expected: `index.html` exists, `assets/` directory contains JS and CSS files.

- [ ] **Step 5: Commit vendored assets**

```bash
git add scripts/build-liam-erd.sh vendor/assets/liam-erd/
git commit -m "Vendor Liam ERD v0.7.24 pre-built assets"
```

---

### Task 8: Integration test in host-woods

**Files:** No code changes — this is a validation task.

- [ ] **Step 1: Push the erd branch**

Run: `git push origin erd`

- [ ] **Step 2: Update host-woods Gemfile to point to erd branch**

In the host-woods worktree (`/path/to/work/myapp/host-woods/Gemfile`), change:

```ruby
gem 'woods', git: 'https://github.com/lost-in-the/woods', branch: 'erd'
```

- [ ] **Step 3: Bundle install in the container**

Run from myapp:
```bash
cd ~/work/myapp && docker compose exec host-woods bundle install
```

- [ ] **Step 4: Enable ERD in admin initializer**

In host-woods, update `config/initializers/woods.rb` to add:

```ruby
config.erd_enabled = true
```

- [ ] **Step 5: Run extraction to populate indexes and foreign_keys**

Run from myapp:
```bash
cd ~/work/myapp && docker compose exec host-woods bundle exec rake woods:extract
```

- [ ] **Step 6: Restart the app server**

Run from myapp:
```bash
cd ~/work/myapp && docker compose restart host-woods
```

- [ ] **Step 7: Verify ERD renders in the browser**

Navigate to `http://app.acme.me/woods/erd` (or the appropriate local URL for the host-woods app).

Expected: Liam ERD renders with the host app's 212 model tables, columns, and foreign key relationships. The ELK layout engine should arrange the graph interactively.

- [ ] **Step 8: Verify schema.json is generated correctly**

Run: `curl -s http://app.acme.me/woods/erd/schema.json | python3 -m json.tool | head -50`
Expected: Valid JSON with `tables`, `enums`, `extensions` keys. Tables should include models like `accounts`, `products`, `orders`, etc.
