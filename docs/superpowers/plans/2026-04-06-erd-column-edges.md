# ERD Column-Level Edges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ERD-style column-level edges with cardinality markers, configurable column display, readonly canvas, and URL state to the Svelte Flow visualization.

**Architecture:** New `AssociationEdgeBuilder` reads association metadata from `unit_metadata` to produce edges with FK→PK handle routing and relationship type. Frontend removes the center-only column gate so all model nodes show columns. SVG markers render cardinality. Show mode selector persists to localStorage, center node to URL.

**Tech Stack:** Ruby (gem), Svelte 5 / @xyflow/svelte (frontend), RSpec (tests)

**Spec:** `docs/superpowers/specs/2026-04-06-erd-column-edges-design.md`

---

### Task 1: AssociationEdgeBuilder — core class

**Files:**
- Create: `lib/woods/svelte_flow/association_edge_builder.rb`
- Test: `spec/svelte_flow/association_edge_builder_spec.rb`

- [ ] **Step 1: Write the failing test for basic belongs_to edge**

```ruby
# spec/svelte_flow/association_edge_builder_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'woods/svelte_flow/association_edge_builder'

RSpec.describe Woods::SvelteFlow::AssociationEdgeBuilder do
  describe '#build' do
    it 'produces a belongs_to edge with FK→PK direction' do
      unit_metadata = {
        'Order' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' },
              { 'name' => 'account_id', 'type' => 'bigint' }
            ],
            'associations' => [
              { 'type' => 'belongs_to', 'target' => 'Account', 'foreign_key' => 'account_id' }
            ]
          }
        },
        'Account' => {
          'type' => 'model',
          'metadata' => {
            'primary_key' => 'id',
            'columns' => [
              { 'name' => 'id', 'type' => 'bigint' }
            ],
            'associations' => []
          }
        }
      }

      builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
      edges = builder.build

      expect(edges.size).to eq(1)
      edge = edges.first
      expect(edge['source']).to eq('Order')
      expect(edge['target']).to eq('Account')
      expect(edge['type']).to eq('association')
      expect(edge['data']['via']).to eq('belongs_to')
      expect(edge['data']['foreignKey']).to eq('account_id')
      expect(edge['data']['sourceHandle']).to eq('Order-account_id')
      expect(edge['data']['targetHandle']).to eq('Account-id')
      expect(edge['data']['through']).to be_nil
      expect(edge['data']['polymorphic']).to eq(false)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/svelte_flow/association_edge_builder_spec.rb -v`
Expected: FAIL with `cannot load such file -- woods/svelte_flow/association_edge_builder`

- [ ] **Step 3: Implement AssociationEdgeBuilder**

```ruby
# lib/woods/svelte_flow/association_edge_builder.rb
# frozen_string_literal: true

require 'set'

module Woods
  module SvelteFlow
    # Builds ERD-style edges from association metadata.
    #
    # Unlike EdgeBuilder (which reads flat dependency edges from DependencyGraph),
    # this class reads rich association metadata from unit_metadata to produce
    # edges with FK→PK handle routing, relationship type, and cardinality info.
    #
    # Edge direction convention: source always holds the FK column, target holds the PK.
    # belongs_to edges keep natural direction. has_many/has_one edges are flipped so
    # the FK-holding model is always the source.
    #
    # Deduplication: Rails associations are bidirectional (Account has_many :orders,
    # Order belongs_to :account). We deduplicate by canonical key:
    # "{fk_table}-{fk_column}-{pk_table}". First occurrence wins.
    #
    # @example
    #   builder = AssociationEdgeBuilder.new(
    #     unit_metadata: metadata_hash,
    #     cycle_edges: Set.new([["Order", "Account"]])
    #   )
    #   builder.build  # => [{ "id" => "assoc-...", "source" => "Order", ... }]
    #
    class AssociationEdgeBuilder
      # @param unit_metadata [Hash<String, Hash>] Raw unit metadata keyed by identifier
      # @param cycle_edges [Set<Array<String>>] Set of [source, target] pairs forming cycles
      def initialize(unit_metadata:, cycle_edges: Set.new)
        @unit_metadata = unit_metadata
        @cycle_edges = cycle_edges
      end

      # Build Svelte Flow edge objects for all model associations.
      #
      # @return [Array<Hash>] Svelte Flow edge objects with ERD semantics
      def build
        seen = Set.new
        edges = []

        @unit_metadata.each do |identifier, unit|
          unit_type = (unit['type'] || unit[:type])&.to_s
          next unless unit_type == 'model'

          metadata = unit['metadata'] || unit[:metadata] || {}
          associations = metadata['associations'] || metadata[:associations] || []
          primary_key = metadata['primary_key'] || metadata[:primary_key] || 'id'

          associations.each do |assoc|
            edge = build_association_edge(identifier, primary_key, assoc)
            next unless edge

            canonical = edge[:canonical_key]
            next if seen.include?(canonical)

            seen.add(canonical)
            edges << edge[:edge]
          end
        end

        edges
      end

      private

      # Build a single association edge with FK→PK direction.
      #
      # @param identifier [String] Source model identifier
      # @param primary_key [String] Source model's primary key column
      # @param assoc [Hash] Association metadata
      # @return [Hash, nil] { canonical_key:, edge: } or nil if target not in metadata
      def build_association_edge(identifier, primary_key, assoc) # rubocop:disable Metrics
        macro = (assoc['type'] || assoc[:type])&.to_s
        target = assoc['target'] || assoc[:target]
        foreign_key = (assoc['foreign_key'] || assoc[:foreign_key])&.to_s
        through = assoc['through'] || assoc[:through]
        polymorphic = assoc['polymorphic'] || assoc[:polymorphic] || false

        return nil unless target && @unit_metadata.key?(target)
        return nil unless foreign_key

        target_meta = @unit_metadata[target]
        target_pk = resolve_primary_key(target_meta)

        source_model, target_model, source_handle, target_handle =
          resolve_direction(identifier, target, foreign_key, primary_key, target_pk, macro)

        canonical_key = "#{source_model}-#{foreign_key}-#{target_model}"
        is_cycle = @cycle_edges.include?([identifier, target]) ||
                   @cycle_edges.include?([target, identifier])

        edge_id = "assoc-#{identifier}-#{macro}-#{target}-#{foreign_key}"

        {
          canonical_key: canonical_key,
          edge: {
            'id' => edge_id,
            'source' => source_model,
            'target' => target_model,
            'type' => 'association',
            'data' => {
              'via' => macro,
              'foreignKey' => foreign_key,
              'sourceHandle' => source_handle,
              'targetHandle' => target_handle,
              'through' => through&.to_s,
              'polymorphic' => polymorphic,
              'isCycle' => is_cycle
            }
          }
        }
      end

      # Resolve edge direction so source always holds the FK.
      #
      # @return [Array<String>] [source_model, target_model, source_handle, target_handle]
      def resolve_direction(identifier, target, foreign_key, my_pk, target_pk, macro)
        case macro
        when 'belongs_to'
          # identifier has the FK column → identifier is source
          [identifier, target, "#{identifier}-#{foreign_key}", "#{target}-#{target_pk}"]
        when 'has_many', 'has_one'
          # target has the FK column → target is source
          [target, identifier, "#{target}-#{foreign_key}", "#{identifier}-#{my_pk}"]
        when 'has_and_belongs_to_many'
          # Join table owns both FKs — keep identifier as source for consistency
          [identifier, target, "#{identifier}-#{foreign_key}", "#{target}-#{target_pk}"]
        else
          [identifier, target, "#{identifier}-#{foreign_key}", "#{target}-#{target_pk}"]
        end
      end

      # Resolve the primary key for a target model from its metadata.
      #
      # @param target_meta [Hash] Unit metadata for the target model
      # @return [String]
      def resolve_primary_key(target_meta)
        meta = target_meta['metadata'] || target_meta[:metadata] || {}
        meta['primary_key'] || meta[:primary_key] || 'id'
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/svelte_flow/association_edge_builder_spec.rb -v`
Expected: PASS

- [ ] **Step 5: Add tests for has_many flipping, deduplication, through, polymorphic, cycles**

```ruby
# Add to the existing spec file

it 'flips has_many edges so FK holder is source' do
  unit_metadata = {
    'Account' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
        'associations' => [
          { 'type' => 'has_many', 'target' => 'Order', 'foreign_key' => 'account_id' }
        ]
      }
    },
    'Order' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint' },
          { 'name' => 'account_id', 'type' => 'bigint' }
        ],
        'associations' => []
      }
    }
  }

  builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
  edges = builder.build

  expect(edges.size).to eq(1)
  edge = edges.first
  # has_many flipped: Order (FK holder) is source, Account (PK) is target
  expect(edge['source']).to eq('Order')
  expect(edge['target']).to eq('Account')
  expect(edge['data']['via']).to eq('has_many')
  expect(edge['data']['sourceHandle']).to eq('Order-account_id')
  expect(edge['data']['targetHandle']).to eq('Account-id')
end

it 'deduplicates bidirectional associations' do
  unit_metadata = {
    'Account' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
        'associations' => [
          { 'type' => 'has_many', 'target' => 'Order', 'foreign_key' => 'account_id' }
        ]
      }
    },
    'Order' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint' },
          { 'name' => 'account_id', 'type' => 'bigint' }
        ],
        'associations' => [
          { 'type' => 'belongs_to', 'target' => 'Account', 'foreign_key' => 'account_id' }
        ]
      }
    }
  }

  builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
  edges = builder.build

  # Both describe the same FK relationship — only one edge produced
  expect(edges.size).to eq(1)
end

it 'includes through field for has_many :through' do
  unit_metadata = {
    'Doctor' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
        'associations' => [
          { 'type' => 'has_many', 'target' => 'Patient', 'foreign_key' => 'doctor_id',
            'through' => 'Appointment' }
        ]
      }
    },
    'Patient' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
        'associations' => []
      }
    }
  }

  builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
  edges = builder.build

  expect(edges.size).to eq(1)
  expect(edges.first['data']['through']).to eq('Appointment')
end

it 'flags polymorphic associations' do
  unit_metadata = {
    'Comment' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint' },
          { 'name' => 'commentable_id', 'type' => 'bigint' }
        ],
        'associations' => [
          { 'type' => 'belongs_to', 'target' => 'Post', 'foreign_key' => 'commentable_id',
            'polymorphic' => true }
        ]
      }
    },
    'Post' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
        'associations' => []
      }
    }
  }

  builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
  edges = builder.build

  expect(edges.first['data']['polymorphic']).to eq(true)
end

it 'marks cycle edges' do
  unit_metadata = {
    'A' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint' },
          { 'name' => 'b_id', 'type' => 'bigint' }
        ],
        'associations' => [
          { 'type' => 'belongs_to', 'target' => 'B', 'foreign_key' => 'b_id' }
        ]
      }
    },
    'B' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
        'associations' => []
      }
    }
  }

  cycle_edges = Set.new([%w[A B]])
  builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: cycle_edges)
  edges = builder.build

  expect(edges.first['data']['isCycle']).to eq(true)
end

it 'skips non-model units' do
  unit_metadata = {
    'UsersController' => {
      'type' => 'controller',
      'metadata' => {
        'associations' => []
      }
    }
  }

  builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
  expect(builder.build).to eq([])
end

it 'skips associations whose target is not in unit_metadata' do
  unit_metadata = {
    'Order' => {
      'type' => 'model',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint' }],
        'associations' => [
          { 'type' => 'belongs_to', 'target' => 'MissingModel', 'foreign_key' => 'missing_model_id' }
        ]
      }
    }
  }

  builder = described_class.new(unit_metadata: unit_metadata, cycle_edges: Set.new)
  expect(builder.build).to eq([])
end
```

- [ ] **Step 6: Run all tests to verify they pass**

Run: `bundle exec rspec spec/svelte_flow/association_edge_builder_spec.rb -v`
Expected: All PASS

- [ ] **Step 7: Commit**

```bash
git add lib/woods/svelte_flow/association_edge_builder.rb spec/svelte_flow/association_edge_builder_spec.rb
git commit -m "Add AssociationEdgeBuilder for ERD-style FK→PK edges"
```

---

### Task 2: Integrate AssociationEdgeBuilder into Transformer

**Files:**
- Modify: `lib/woods/svelte_flow/transformer.rb`
- Modify: `lib/woods/svelte_flow/edge_builder.rb`
- Test: `spec/svelte_flow/transformer_spec.rb` (existing, add cases)

- [ ] **Step 1: Write the failing test**

```ruby
# In spec/svelte_flow/transformer_spec.rb (or new file if transformer_spec doesn't exist)
# Add a test that verifies dependency_graph_data produces association-type edges

it 'produces association edges for model-to-model relationships' do
  # Setup graph with two models that have associations in unit_metadata
  # Verify edges array contains type: 'association' edges with ERD data
  # Verify non-model edges still use type: 'default'
end
```

Check if `spec/svelte_flow/transformer_spec.rb` exists first to determine where to add the test.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/svelte_flow/transformer_spec.rb -v`
Expected: FAIL — no association-type edges produced

- [ ] **Step 3: Add exclude_pairs to EdgeBuilder**

In `lib/woods/svelte_flow/edge_builder.rb`, add an `exclude_pairs` parameter:

```ruby
def initialize(edges:, valid_node_ids:, cycle_edges: Set.new, exclude_pairs: Set.new)
  @edges = edges
  @valid_node_ids = valid_node_ids
  @cycle_edges = cycle_edges
  @exclude_pairs = exclude_pairs
end
```

In `build`, skip edges where `[source, target]` is in `@exclude_pairs`:

```ruby
def build
  result = []
  @edges.each do |source, targets|
    next unless @valid_node_ids.include?(source)
    targets.each do |target|
      next unless @valid_node_ids.include?(target)
      next if @exclude_pairs.include?([source, target])
      result << build_dependency_edge(source, target)
    end
  end
  result
end
```

- [ ] **Step 4: Update Transformer#dependency_graph_data to use both builders**

In `lib/woods/svelte_flow/transformer.rb`, after building the node list:

```ruby
require_relative 'association_edge_builder'

# In dependency_graph_data method, replace edge_builder usage:

# Build association edges for model↔model relationships
assoc_builder = AssociationEdgeBuilder.new(
  unit_metadata: @unit_metadata,
  cycle_edges: cycle_edges
)
association_edges = assoc_builder.build

# Collect model↔model pairs that AssociationEdgeBuilder handles
# so EdgeBuilder skips them (avoids duplicate edges)
model_ids = Set.new
@unit_metadata.each do |id, meta|
  unit_type = (meta['type'] || meta[:type])&.to_s
  model_ids.add(id) if unit_type == 'model'
end

exclude_pairs = Set.new
edges.each do |source, targets|
  next unless model_ids.include?(source)
  targets.each do |target|
    exclude_pairs.add([source, target]) if model_ids.include?(target)
  end
end

edge_builder = EdgeBuilder.new(
  edges: edges,
  valid_node_ids: valid_ids,
  cycle_edges: cycle_edges,
  exclude_pairs: exclude_pairs
)

{
  'nodes' => node_builder.build,
  'edges' => association_edges + edge_builder.build
}
```

- [ ] **Step 5: Run tests**

Run: `bundle exec rspec spec/svelte_flow/ -v`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add lib/woods/svelte_flow/transformer.rb lib/woods/svelte_flow/edge_builder.rb spec/svelte_flow/
git commit -m "Integrate AssociationEdgeBuilder into Transformer for ERD edges"
```

---

### Task 3: ModelNode — show columns on all nodes, update handle IDs

**Files:**
- Modify: `frontend/src/components/ModelNode.svelte`

- [ ] **Step 1: Remove the `{#if isCenter}` gate on column rendering**

Replace the conditional block (lines 54-78) so all model nodes render columns:

```svelte
{#each columns as col}
  <div class="column-row">
    <Handle
      type="target"
      position={Position.Left}
      id={`${data.label}-${col.name}`}
      style="top: auto; left: -4px; width: 8px; height: 8px; background: {col.foreign ? COLORS.edgeActive : 'transparent'}; border: none;"
    />
    <span class="col-icon">{columnIcon(col)}</span>
    <span class="col-name">{col.name}</span>
    <span class="col-type">{col.type || ''}</span>
    <Handle
      type="source"
      position={Position.Right}
      id={`${data.label}-${col.name}`}
      style="top: auto; right: -4px; width: 8px; height: 8px; background: {col.primary ? COLORS.edgeActive : 'transparent'}; border: none;"
    />
  </div>
{/each}
```

Note: Handle IDs change from `col-left-{name}` / `col-right-{name}` to `{modelName}-{colName}`. Both left and right handles on the same column share the same ID — SvelteFlow disambiguates by `type` (source vs target).

- [ ] **Step 2: Remove the compact-summary fallback**

Delete the `{:else if columns.length > 0}` block that showed `"N columns"`.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/ModelNode.svelte
git commit -m "Show columns on all model nodes, update handle IDs to {model}-{col}"
```

---

### Task 4: Column collapse for large models (20+ columns)

**Files:**
- Modify: `frontend/src/components/ModelNode.svelte`

- [ ] **Step 1: Add collapsed state and visible columns derivation**

```svelte
<script>
  // ... existing imports and props ...

  const COLLAPSE_THRESHOLD = 20;
  const VISIBLE_WHEN_COLLAPSED = 8;

  let expanded = $state(false);

  const visibleColumns = $derived.by(() => {
    if (columns.length <= COLLAPSE_THRESHOLD || expanded) return columns;

    // Show first N + all PK/FK columns
    const first = columns.slice(0, VISIBLE_WHEN_COLLAPSED);
    const keyColumns = columns.slice(VISIBLE_WHEN_COLLAPSED).filter(
      (c) => c.primary || c.foreign
    );
    // Deduplicate (in case a key column is in the first N)
    const seen = new Set(first.map((c) => c.name));
    const extra = keyColumns.filter((c) => !seen.has(c.name));
    return [...first, ...extra];
  });

  const hiddenCount = $derived(
    columns.length <= COLLAPSE_THRESHOLD || expanded
      ? 0
      : columns.length - visibleColumns.length
  );
</script>
```

- [ ] **Step 2: Update the column rendering loop**

Replace `{#each columns as col}` with `{#each visibleColumns as col}` and add the expand row:

```svelte
{#each visibleColumns as col}
  <!-- ... existing column row ... -->
{/each}
{#if hiddenCount > 0}
  <button class="expand-columns-row" onclick={() => expanded = true}>
    + {hiddenCount} more
  </button>
{/if}
```

- [ ] **Step 3: Add CSS for the expand row**

```css
.expand-columns-row {
  display: block;
  width: 100%;
  padding: 3px 10px;
  font-size: 9px;
  color: #64748b;
  background: transparent;
  border: none;
  border-top: 1px solid #334155;
  cursor: pointer;
  text-align: left;
}
.expand-columns-row:hover {
  color: #94a3b8;
  background: rgba(51, 65, 85, 0.3);
}
```

- [ ] **Step 4: Commit**

```bash
git add frontend/src/components/ModelNode.svelte
git commit -m "Add column collapse for models with 20+ columns"
```

---

### Task 5: Show mode selector

**Files:**
- Create: `frontend/src/components/ShowModeSelector.svelte`
- Modify: `frontend/src/App.svelte`
- Modify: `frontend/src/components/ModelNode.svelte`
- Modify: `frontend/src/components/ColumnLayout.svelte`
- Modify: `frontend/src/lib/column-layout.js`

- [ ] **Step 1: Create ShowModeSelector component**

```svelte
<!-- frontend/src/components/ShowModeSelector.svelte -->
<script>
  let { mode, onModeChange } = $props();

  const modes = [
    { value: 'all_fields', label: 'All Fields' },
    { value: 'key_only', label: 'Key Only' },
    { value: 'table_name', label: 'Table Name' },
  ];
</script>

<div class="show-mode-selector">
  {#each modes as m}
    <button
      class="mode-btn"
      class:active={mode === m.value}
      onclick={() => onModeChange(m.value)}
    >
      {m.label}
    </button>
  {/each}
</div>

<style>
  .show-mode-selector {
    display: flex;
    gap: 1px;
    background: #334155;
    border-radius: 6px;
    overflow: hidden;
    font-size: 11px;
  }
  .mode-btn {
    padding: 4px 10px;
    background: #1e293b;
    color: #94a3b8;
    border: none;
    cursor: pointer;
    white-space: nowrap;
  }
  .mode-btn:hover {
    background: #334155;
    color: #e2e8f0;
  }
  .mode-btn.active {
    background: #475569;
    color: #e2e8f0;
    font-weight: 600;
  }
</style>
```

- [ ] **Step 2: Add show mode state to App.svelte**

```js
// In App.svelte <script>
const SHOW_MODE_KEY = 'woods-flow-show-mode';
let showMode = $state(localStorage.getItem(SHOW_MODE_KEY) || 'all_fields');

function handleShowModeChange(mode) {
  showMode = mode;
  localStorage.setItem(SHOW_MODE_KEY, mode);
}
```

- [ ] **Step 3: Add ShowModeSelector to the header in App.svelte template**

```svelte
<div class="header">
  <h1>Woods <span>Visualize</span></h1>
  <div class="header-controls">
    <ShowModeSelector mode={showMode} onModeChange={handleShowModeChange} />
  </div>
</div>
```

Add import: `import ShowModeSelector from './components/ShowModeSelector.svelte';`

Add CSS:
```css
.header {
  /* existing styles... */
  justify-content: space-between;
}
.header-controls {
  display: flex;
  align-items: center;
  gap: 8px;
}
```

- [ ] **Step 4: Pass showMode through ColumnLayout to ModelNode**

In `App.svelte`, pass `showMode` to `ColumnLayout`:
```svelte
<ColumnLayout {allNodes} {allEdges} {visibleNodeIds} {centerNodeId}
  {expandedBranches} {loading} {focusNodeId} {showMode}
  onNodeSelect={handleNodeSelect} onCanvasClick={handleCanvasClick} />
```

In `ColumnLayout.svelte`, accept `showMode` prop and pass it into node data:
```js
let { ..., showMode } = $props();

// In visibleNodes derivation, add showMode to data:
data: { ...n.data, isCenter: n.id === centerNodeId, showMode },
```

- [ ] **Step 5: Update ModelNode to respect showMode**

In `ModelNode.svelte`:
```js
const showMode = $derived(data?.showMode || 'all_fields');

const visibleColumns = $derived.by(() => {
  if (showMode === 'table_name') return [];
  if (showMode === 'key_only') return columns.filter((c) => c.primary || c.foreign);
  // all_fields mode — use collapse logic
  if (columns.length <= COLLAPSE_THRESHOLD || expanded) return columns;
  const first = columns.slice(0, VISIBLE_WHEN_COLLAPSED);
  const keyColumns = columns.slice(VISIBLE_WHEN_COLLAPSED).filter((c) => c.primary || c.foreign);
  const seen = new Set(first.map((c) => c.name));
  const extra = keyColumns.filter((c) => !seen.has(c.name));
  return [...first, ...extra];
});
```

- [ ] **Step 6: Update column-layout.js estimateNodeHeight**

```js
function estimateNodeHeight(node) {
  const cols = node.data?.columns?.length || 0;
  const showMode = node.data?.showMode || 'all_fields';

  if (showMode === 'table_name' || cols === 0) return BASE_NODE_HEIGHT;
  if (showMode === 'key_only') {
    const keyCount = (node.data?.columns || []).filter((c) => c.primary || c.foreign).length;
    return BASE_NODE_HEIGHT + keyCount * COLUMN_ROW_HEIGHT;
  }

  // all_fields — account for collapse
  const COLLAPSE_THRESHOLD = 20;
  const VISIBLE_WHEN_COLLAPSED = 8;
  if (cols <= COLLAPSE_THRESHOLD) return BASE_NODE_HEIGHT + cols * COLUMN_ROW_HEIGHT;

  const keyBeyond = (node.data?.columns || []).slice(VISIBLE_WHEN_COLLAPSED).filter((c) => c.primary || c.foreign).length;
  const visibleCount = VISIBLE_WHEN_COLLAPSED + keyBeyond + 1; // +1 for "more" row
  return BASE_NODE_HEIGHT + visibleCount * COLUMN_ROW_HEIGHT;
}
```

Remove the `isCenter` parameter from `estimateNodeHeight` calls in `layoutColumns`.

- [ ] **Step 7: Pass showMode to layoutColumns and update its signature**

In `column-layout.js`, update `layoutColumns` to not pass `isCenter` to `estimateNodeHeight`:

```js
const height = estimateNodeHeight(node);
```

- [ ] **Step 8: Commit**

```bash
git add frontend/src/components/ShowModeSelector.svelte frontend/src/components/ModelNode.svelte \
       frontend/src/components/ColumnLayout.svelte frontend/src/lib/column-layout.js \
       frontend/src/App.svelte
git commit -m "Add show mode selector (All Fields / Key Only / Table Name) with localStorage"
```

---

### Task 6: SVG cardinality markers and edge rendering

**Files:**
- Create: `frontend/src/components/CardinalityMarkers.svelte`
- Modify: `frontend/src/components/ColumnLayout.svelte`

- [ ] **Step 1: Create CardinalityMarkers component**

```svelte
<!-- frontend/src/components/CardinalityMarkers.svelte -->
<script>
  // No props — this is a static SVG defs block
</script>

<svg style="position: absolute; width: 0; height: 0;">
  <defs>
    <!-- Single bar marker (one) -->
    <marker
      id="marker-bar"
      viewBox="0 0 10 14"
      refX="5"
      refY="7"
      markerWidth="10"
      markerHeight="14"
      orient="auto-start-reverse"
    >
      <line x1="5" y1="0" x2="5" y2="14" stroke="#475569" stroke-width="2" />
    </marker>

    <!-- Crow's foot marker (many) -->
    <marker
      id="marker-crow-foot"
      viewBox="0 0 16 14"
      refX="1"
      refY="7"
      markerWidth="16"
      markerHeight="14"
      orient="auto-start-reverse"
    >
      <line x1="14" y1="0" x2="1" y2="7" stroke="#475569" stroke-width="1.5" />
      <line x1="14" y1="14" x2="1" y2="7" stroke="#475569" stroke-width="1.5" />
      <line x1="14" y1="0" x2="14" y2="14" stroke="#475569" stroke-width="1.5" />
    </marker>
  </defs>
</svg>
```

- [ ] **Step 2: Update ColumnLayout edge derivation**

Replace the existing `visibleEdges` derivation in `ColumnLayout.svelte`. Remove `findFkColumn` entirely. Edges now use handle data directly from the backend:

```js
const visibleEdges = $derived.by(() => {
  return allEdges
    .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
    .filter((e) => e.source === centerNodeId || e.target === centerNodeId)
    .map((e) => {
      const via = e.data?.via;
      const isAssociation = e.type === 'association';

      const edge = {
        ...e,
        type: isAssociation ? 'smoothstep' : 'default',
        animated: false,
        style: e.data?.isCycle
          ? 'stroke: #64748b; stroke-width: 1px; stroke-dasharray: 4 3;'
          : e.data?.through
            ? 'stroke: #475569; stroke-width: 1px; opacity: 0.4;'
            : 'stroke: #475569; stroke-width: 1.5px;',
      };

      // Handle IDs come directly from edge data — no heuristic matching
      if (isAssociation) {
        if (e.data?.sourceHandle) edge.sourceHandle = e.data.sourceHandle;
        if (e.data?.targetHandle) edge.targetHandle = e.data.targetHandle;
      }

      // Cardinality markers
      if (isAssociation && via) {
        if (via === 'has_many') {
          edge.markerStart = { type: 'marker-crow-foot' };
          edge.markerEnd = { type: 'marker-bar' };
        } else if (via === 'has_and_belongs_to_many') {
          edge.markerStart = { type: 'marker-crow-foot' };
          edge.markerEnd = { type: 'marker-crow-foot' };
        } else {
          // belongs_to, has_one
          edge.markerEnd = { type: 'marker-bar' };
        }
      }

      return edge;
    });
});
```

- [ ] **Step 3: Delete the findFkColumn function from ColumnLayout.svelte**

Remove the entire `findFkColumn` function (lines ~93-102 in current file).

- [ ] **Step 4: Add CardinalityMarkers to the SvelteFlow container**

```svelte
<script>
  import CardinalityMarkers from './CardinalityMarkers.svelte';
  // ... existing imports ...
</script>

<!-- Inside the SvelteFlow block: -->
<SvelteFlow ...>
  <Controls />
  <MiniMap />
  <Background />
  <FocusNode nodeId={focusNodeId} />
  <CardinalityMarkers />
</SvelteFlow>
```

Note: SvelteFlow's `markerStart`/`markerEnd` reference marker IDs by `type` property. The marker `id` attributes in the SVG defs must match. If SvelteFlow wraps marker references differently (e.g., `url(#marker-bar)`), adjust the edge `markerStart`/`markerEnd` format accordingly. Check @xyflow/svelte docs via Context7 if the format doesn't work on first try.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/CardinalityMarkers.svelte frontend/src/components/ColumnLayout.svelte
git commit -m "Add SVG cardinality markers and column-level edge routing"
```

---

### Task 7: Readonly canvas

**Files:**
- Modify: `frontend/src/components/ColumnLayout.svelte`

- [ ] **Step 1: Add readonly props to SvelteFlow**

```svelte
<SvelteFlow
  bind:nodes={layoutedNodes}
  bind:edges={layoutedEdges}
  {nodeTypes}
  onnodeclick={handleNodeClick}
  onpaneclick={handlePaneClick}
  nodesConnectable={false}
  edgesUpdatable={false}
  nodesDraggable={true}
  fitView
  fitViewOptions={{ padding: 0.12, maxZoom: 0.85 }}
  minZoom={0.1}
  maxZoom={2}
>
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/ColumnLayout.svelte
git commit -m "Make canvas readonly — disable edge creation and modification"
```

---

### Task 8: URL state for center node

**Files:**
- Modify: `frontend/src/App.svelte`

- [ ] **Step 1: Read center from URL on initialization**

```js
// In App.svelte <script>, before loadFullGraph():

function getCenterFromUrl() {
  const params = new URLSearchParams(window.location.search);
  return params.get('center') || null;
}

function updateUrl(centerId) {
  const url = new URL(window.location.href);
  if (centerId) {
    url.searchParams.set('center', centerId);
  } else {
    url.searchParams.delete('center');
  }
  history.replaceState({}, '', url);
}
```

- [ ] **Step 2: Update setCenterNode to call updateUrl**

```js
function setCenterNode(id) {
  centerNodeId = id;
  activeNodeId = id;
  expandedBranches = new Map();
  focusNodeId = { id, t: Date.now() };
  updateUrl(id);

  recentNodes = [id, ...recentNodes.filter((r) => r !== id)].slice(0, 10);
}
```

- [ ] **Step 3: Use URL center on initial load**

In `loadFullGraph`, after setting `allNodes`:

```js
// Auto-select center: URL param first, then highest pagerank
if (!centerNodeId && rawNodes.length > 0) {
  const urlCenter = getCenterFromUrl();
  const targetId = urlCenter && rawNodes.some((n) => n.id === urlCenter)
    ? urlCenter
    : [...rawNodes].sort((a, b) => (b.data?.pagerank || 0) - (a.data?.pagerank || 0))[0].id;
  setCenterNode(targetId);
}
```

- [ ] **Step 4: Commit**

```bash
git add frontend/src/App.svelte
git commit -m "Reflect center node in URL query param (?center=X)"
```

---

### Task 9: Build frontend and update gem assets

**Files:**
- Modify: `frontend/` (build output)
- Modify: `lib/woods/svelte_flow/assets/` (copy built files)

- [ ] **Step 1: Build the frontend**

```bash
cd frontend && npm run build
```

- [ ] **Step 2: Copy built assets to gem**

```bash
cp -r frontend/dist/* lib/woods/svelte_flow/assets/
```

- [ ] **Step 3: Verify the build output**

Check that `lib/woods/svelte_flow/assets/` contains the updated JS and CSS bundles.

- [ ] **Step 4: Commit**

```bash
git add lib/woods/svelte_flow/assets/
git commit -m "Rebuild frontend assets with ERD column-level edges"
```

---

### Task 10: Integration test in host app

**Files:** None in gem — test runs in host app

- [ ] **Step 1: Run extraction in host app**

```bash
# cd to host worktree (admin/gal-1438 or myapp)
docker compose exec app bundle exec rake woods:extract
docker compose exec app bundle exec rake woods:svelte_flow_export
```

- [ ] **Step 2: Start the visualization server and verify in browser**

Open the visualization, center on Account (or use `?center=Account`).

Verify acceptance criteria:
1. All visible model nodes show columns
2. Edges connect at column level (FK→PK handles)
3. Crow's foot markers on has_many edges
4. Bar markers on belongs_to/has_one edges
5. Show mode selector works (All Fields / Key Only / Table Name)
6. Show mode persists on reload (localStorage)
7. URL updates with `?center=X` on navigation
8. Cannot draw new connections (readonly)
9. Only center-connected edges visible
10. Large models (20+ columns) show collapse with "+ N more"

- [ ] **Step 3: Commit any final adjustments**
