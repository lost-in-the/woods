# User Journey Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a static "Journey Mode" to the Liam ERD that lets users pick a GET route as an entry point and see the reachable subgraph (controllers → services → jobs → models) via navigation edges.

**Architecture:** Backend emits a slim `entryPoints` array into `schema.json` (projection of routes + extracted controllers). Frontend adds a pure BFS walker over the existing `nodes[*].dependencies` graph, a `useJourneyMode` context/hook, and overlays (sticky banner, edge legend, node/edge CSS classes) on the existing React Flow canvas. Entry-point selection is wired into the existing ⌘K command palette and a right-click "Start journey from here" menu item.

**Tech Stack:** Ruby (RSpec) for the backend projection. TypeScript + React + Valibot + cmdk + React Flow + Vitest for the frontend.

**Spec:** `docs/superpowers/specs/2026-04-21-user-journey-design.md`

---

## File Structure

### New files (Ruby)
- `lib/woods/erd/entry_point_index_builder.rb` — reads routes + controllers, emits the entry-point array.
- `spec/erd/entry_point_index_builder_spec.rb` — unit tests.

### Modified files (Ruby)
- `lib/woods/erd/schema_generator.rb` — appends `entryPoints` to schema when routes dir is present.
- `spec/erd/schema_generator_spec.rb` — adds coverage for entry-point integration.

### New files (frontend)
- `frontend/liam-erd/packages/erd-core/src/features/journey/walker.ts`
- `frontend/liam-erd/packages/erd-core/src/features/journey/walker.test.ts`
- `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyContext.tsx`
- `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.ts`
- `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.test.tsx`
- `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyBanner.tsx`
- `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyLegend.tsx`
- `frontend/liam-erd/packages/erd-core/src/features/journey/journey.module.css`
- `frontend/liam-erd/packages/erd-core/src/features/journey/index.ts`

### Modified files (frontend)
- `frontend/liam-erd/packages/schema/src/schema/schema.ts` — add `entryPointSchema` + optional `entryPoints` field.
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPalette.tsx` — add "Entry Points" section.
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx` — wrap with `JourneyProvider`; render banner + legend when active.
- `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent` — apply journey CSS classes to nodes/edges; add context menu item.

---

## Task 1: Backend — EntryPointIndexBuilder (happy path)

**Files:**
- Create: `lib/woods/erd/entry_point_index_builder.rb`
- Create: `spec/erd/entry_point_index_builder_spec.rb`

- [ ] **Step 1.1: Write the failing test (happy path)**

Create `spec/erd/entry_point_index_builder_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/erd/entry_point_index_builder'

RSpec.describe Woods::Erd::EntryPointIndexBuilder do
  let(:output_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(output_dir) }

  def write_route(verb:, path:, controller:, action:, id: "#{verb}_#{path}")
    routes_dir = File.join(output_dir, 'routes')
    FileUtils.mkdir_p(routes_dir)
    unit = {
      'type' => 'route',
      'identifier' => id,
      'metadata' => { 'verb' => verb, 'path' => path, 'controller' => controller, 'action' => action }
    }
    File.write(File.join(routes_dir, "#{id.gsub(/[^a-z0-9]/i, '_')}.json"), JSON.generate(unit))
  end

  def write_controller(identifier)
    controllers_dir = File.join(output_dir, 'controllers')
    FileUtils.mkdir_p(controllers_dir)
    unit = { 'type' => 'controller', 'identifier' => identifier, 'metadata' => {} }
    File.write(File.join(controllers_dir, "#{identifier.gsub('::', '__')}.json"), JSON.generate(unit))
  end

  it 'includes GET routes whose controller is extracted' do
    write_route(verb: 'GET', path: '/checkout', controller: 'CheckoutController', action: 'new')
    write_controller('CheckoutController')

    result = described_class.new(output_dir).build

    expect(result).to eq([
      { 'identifier' => 'CheckoutController', 'verb' => 'GET', 'path' => '/checkout', 'action' => 'new' }
    ])
  end
end
```

- [ ] **Step 1.2: Run the test to confirm it fails**

```
bundle exec rspec spec/erd/entry_point_index_builder_spec.rb
```

Expected: `LoadError` — file not found.

- [ ] **Step 1.3: Implement the minimal builder**

Create `lib/woods/erd/entry_point_index_builder.rb`:

```ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

module Woods
  module Erd
    # Projects extracted routes + controllers into a slim entry-point index
    # consumed by the frontend Journey Mode.
    #
    # Emits one row per GET route whose controller is present in the
    # extracted controllers directory. Rows are sorted by path for
    # deterministic schema output.
    class EntryPointIndexBuilder
      def initialize(output_dir)
        @output_dir = Pathname.new(output_dir)
      end

      # @return [Array<Hash{String => String}>] sorted entry-point rows
      def build
        return [] unless routes_dir.directory?

        controllers = load_controller_identifiers
        entries = load_route_units.filter_map { |unit| project(unit, controllers) }
        entries.sort_by { |e| e['path'] }
      end

      private

      def routes_dir
        @output_dir.join('routes')
      end

      def controllers_dir
        @output_dir.join('controllers')
      end

      def load_route_units
        routes_dir.children
                  .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                  .map { |f| JSON.parse(f.read) }
      end

      def load_controller_identifiers
        return [].to_set unless controllers_dir.directory?

        require 'set'
        controllers_dir.children
                       .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                       .map { |f| JSON.parse(f.read)['identifier'] }
                       .to_set
      end

      def project(unit, controllers)
        meta = unit['metadata'] || {}
        return nil unless meta['verb'].to_s.upcase == 'GET'
        return nil unless controllers.include?(meta['controller'])

        {
          'identifier' => meta['controller'],
          'verb' => 'GET',
          'path' => meta['path'].to_s,
          'action' => meta['action'].to_s
        }
      end
    end
  end
end
```

- [ ] **Step 1.4: Run the test, confirm it passes**

```
bundle exec rspec spec/erd/entry_point_index_builder_spec.rb
```

Expected: 1 example, 0 failures.

- [ ] **Step 1.5: Commit**

```
git add lib/woods/erd/entry_point_index_builder.rb spec/erd/entry_point_index_builder_spec.rb
git commit -m "Add EntryPointIndexBuilder for GET route projection"
```

---

## Task 2: Backend — EntryPointIndexBuilder (edge cases)

**Files:**
- Modify: `spec/erd/entry_point_index_builder_spec.rb`

- [ ] **Step 2.1: Add failing tests for filter/sort cases**

Append these `it` blocks inside the existing `RSpec.describe` in `spec/erd/entry_point_index_builder_spec.rb`:

```ruby
  it 'excludes non-GET routes' do
    write_route(verb: 'POST', path: '/checkout', controller: 'CheckoutController', action: 'create')
    write_controller('CheckoutController')

    expect(described_class.new(output_dir).build).to be_empty
  end

  it 'excludes routes whose controller is not extracted' do
    write_route(verb: 'GET', path: '/orphan', controller: 'UnknownController', action: 'index')

    expect(described_class.new(output_dir).build).to be_empty
  end

  it 'preserves namespaced controller identifiers' do
    write_route(verb: 'GET', path: '/admin/users', controller: 'Admin::UsersController', action: 'index')
    write_controller('Admin::UsersController')

    result = described_class.new(output_dir).build

    expect(result.first['identifier']).to eq('Admin::UsersController')
  end

  it 'sorts entries by path ascending' do
    write_controller('CartController')
    write_controller('CheckoutController')
    write_route(verb: 'GET', path: '/checkout', controller: 'CheckoutController', action: 'new', id: 'r2')
    write_route(verb: 'GET', path: '/cart',     controller: 'CartController',     action: 'show', id: 'r1')

    paths = described_class.new(output_dir).build.map { |e| e['path'] }

    expect(paths).to eq(['/cart', '/checkout'])
  end

  it 'returns [] when routes directory is missing' do
    expect(described_class.new(output_dir).build).to eq([])
  end
```

- [ ] **Step 2.2: Run tests, confirm they all pass**

```
bundle exec rspec spec/erd/entry_point_index_builder_spec.rb
```

Expected: 6 examples, 0 failures. (No implementation changes — the Task 1 code already handles these.)

- [ ] **Step 2.3: Commit**

```
git add spec/erd/entry_point_index_builder_spec.rb
git commit -m "Test edge cases for EntryPointIndexBuilder"
```

---

## Task 3: Backend — Wire EntryPointIndexBuilder into SchemaGenerator

**Files:**
- Modify: `lib/woods/erd/schema_generator.rb`
- Modify: `spec/erd/schema_generator_spec.rb`

- [ ] **Step 3.1: Write the failing integration test**

Add this `describe` block inside `spec/erd/schema_generator_spec.rb` (after the existing examples, before the final `end`):

```ruby
  describe '#generate with entry points' do
    it 'includes entryPoints when routes directory is present' do
      FileUtils.mkdir_p(File.join(output_dir, 'routes'))
      FileUtils.mkdir_p(File.join(output_dir, 'controllers'))
      FileUtils.mkdir_p(File.join(output_dir, 'models'))

      File.write(File.join(output_dir, 'routes', 'r1.json'), JSON.generate({
        'type' => 'route',
        'identifier' => 'r1',
        'metadata' => { 'verb' => 'GET', 'path' => '/checkout', 'controller' => 'CheckoutController', 'action' => 'new' }
      }))
      File.write(File.join(output_dir, 'controllers', 'checkout.json'), JSON.generate({
        'type' => 'controller',
        'identifier' => 'CheckoutController',
        'metadata' => {}
      }))
      write_model_unit('Dummy', { 'table_name' => 'dummies', 'table_exists' => true, 'columns' => [] })

      schema = described_class.new(output_dir).generate

      expect(schema['entryPoints']).to eq([
        { 'identifier' => 'CheckoutController', 'verb' => 'GET', 'path' => '/checkout', 'action' => 'new' }
      ])
    end

    it 'omits entryPoints when routes directory is missing' do
      write_model_unit('Dummy', { 'table_name' => 'dummies', 'table_exists' => true, 'columns' => [] })

      schema = described_class.new(output_dir).generate

      expect(schema).not_to have_key('entryPoints')
    end
  end
```

- [ ] **Step 3.2: Run the test, confirm it fails**

```
bundle exec rspec spec/erd/schema_generator_spec.rb -e "entry points"
```

Expected: first test fails — `entryPoints` key missing.

- [ ] **Step 3.3: Wire the builder into SchemaGenerator**

In `lib/woods/erd/schema_generator.rb`:

1. Add a `require 'woods/erd/entry_point_index_builder'` line at the top of the file, below the existing `require` lines.
2. Replace the `generate` method with:

```ruby
      def generate
        models_dir = @output_dir.join('models')
        raise Woods::Error, 'No extracted model data found in output directory' unless models_dir.directory?

        units = load_model_units(models_dir)
        tables = build_tables(units)
        enums = build_enums(units)

        schema = { 'tables' => tables, 'enums' => enums, 'extensions' => {} }

        non_model_layers = @layers.reject { |l| l == :models }
        unless non_model_layers.empty?
          table_lookup = build_table_lookup(units)
          nodes = build_nodes(non_model_layers, table_lookup)
          schema['nodes'] = nodes unless nodes.empty?
        end

        entry_points = EntryPointIndexBuilder.new(@output_dir).build
        schema['entryPoints'] = entry_points unless entry_points.empty?

        schema
      end
```

- [ ] **Step 3.4: Run tests, confirm they pass**

```
bundle exec rspec spec/erd/schema_generator_spec.rb
```

Expected: all existing tests pass, plus the 2 new ones.

- [ ] **Step 3.5: Run full gem spec suite to catch regressions**

```
bundle exec rake spec
```

Expected: no failures.

- [ ] **Step 3.6: Commit**

```
git add lib/woods/erd/schema_generator.rb spec/erd/schema_generator_spec.rb
git commit -m "Emit entryPoints from SchemaGenerator when routes are present"
```

---

## Task 4: Frontend — Valibot schema for entry points

**Files:**
- Modify: `frontend/liam-erd/packages/schema/src/schema/schema.ts`
- Create: `frontend/liam-erd/packages/schema/src/schema/schema.test.ts` (if not already present — check first)

- [ ] **Step 4.1: Check for existing schema test file**

```
ls frontend/liam-erd/packages/schema/src/schema/
```

If `schema.test.ts` exists, skip to Step 4.2 and append to it. If not, you'll create it.

- [ ] **Step 4.2: Write the failing test**

If creating a new file, create `frontend/liam-erd/packages/schema/src/schema/schema.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import * as v from 'valibot'
import { schemaSchema } from './schema'

describe('schemaSchema', () => {
  const baseSchema = {
    tables: {},
    enums: {},
    extensions: {},
  }

  it('accepts a schema without entryPoints', () => {
    expect(() => v.parse(schemaSchema, baseSchema)).not.toThrow()
  })

  it('accepts a schema with an entryPoints array', () => {
    const parsed = v.parse(schemaSchema, {
      ...baseSchema,
      entryPoints: [
        { identifier: 'CheckoutController', verb: 'GET', path: '/checkout', action: 'new' },
      ],
    })
    expect(parsed.entryPoints?.[0].identifier).toBe('CheckoutController')
  })

  it('rejects non-GET entry points', () => {
    expect(() =>
      v.parse(schemaSchema, {
        ...baseSchema,
        entryPoints: [
          { identifier: 'X', verb: 'POST', path: '/x', action: 'create' },
        ],
      }),
    ).toThrow()
  })
})
```

If the file already exists, append only the `describe('schemaSchema', () => { ... })` block.

- [ ] **Step 4.3: Run the test, confirm it fails**

```
cd frontend/liam-erd/packages/schema && pnpm vitest run schema.test.ts
```

Expected: second test fails — `entryPoints` rejected by strict schema.

- [ ] **Step 4.4: Extend `schema.ts` with the entry-point schema**

In `frontend/liam-erd/packages/schema/src/schema/schema.ts`, add after the existing type definitions and before the root `schemaSchema`:

```ts
export const entryPointSchema = v.object({
  identifier: v.string(),
  verb: v.literal('GET'),
  path: v.string(),
  action: v.string(),
})
export type EntryPoint = v.InferOutput<typeof entryPointSchema>

export const entryPointsSchema = v.array(entryPointSchema)
export type EntryPoints = v.InferOutput<typeof entryPointsSchema>
```

Then modify the root `schemaSchema` to include the new optional field:

```ts
export const schemaSchema = v.object({
  tables: tablesSchema,
  enums: enumsSchema,
  extensions: extensionsSchema,
  nodes: v.optional(woodsNodesSchema),
  entryPoints: v.optional(entryPointsSchema),
})
```

- [ ] **Step 4.5: Export `EntryPoint` type from the package barrel**

In `frontend/liam-erd/packages/schema/src/schema/index.ts`, add to the exports:

```ts
export type { EntryPoint, EntryPoints } from './schema'
export { entryPointSchema, entryPointsSchema } from './schema'
```

If the file uses `export *`, this step is already covered — verify by grep.

- [ ] **Step 4.6: Run tests, confirm they pass**

```
cd frontend/liam-erd/packages/schema && pnpm vitest run schema.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 4.7: Commit**

```
git add frontend/liam-erd/packages/schema/src/schema/schema.ts frontend/liam-erd/packages/schema/src/schema/schema.test.ts frontend/liam-erd/packages/schema/src/schema/index.ts
git commit -m "Add entryPointSchema to Valibot root schema"
```

---

## Task 5: Frontend — Pure journey walker

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/walker.ts`
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/walker.test.ts`

- [ ] **Step 5.1: Write the failing tests**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/walker.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { walk, type WalkableSchema } from './walker'

const schema: WalkableSchema = {
  nodes: {
    CheckoutController: {
      dependencies: [
        { target: 'Cart', via: 'link_to' },
        { target: 'ConfirmController', via: 'redirect_to' },
      ],
    },
    ConfirmController: {
      dependencies: [{ target: 'OrderCreator', via: 'form_action' }],
    },
    Cart: { dependencies: [] },
    OrderCreator: {
      dependencies: [{ target: 'CheckoutController', via: 'redirect_to' }],
    },
  },
}

describe('walk', () => {
  it('returns only the entry node when maxDepth is 0', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 0 })
    expect([...result.nodes.keys()]).toEqual(['CheckoutController'])
    expect(result.truncated).toBe(true)
  })

  it('performs BFS to leaves', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 10 })
    expect(result.nodes.get('CheckoutController')?.depth).toBe(0)
    expect(result.nodes.get('Cart')?.depth).toBe(1)
    expect(result.nodes.get('ConfirmController')?.depth).toBe(1)
    expect(result.nodes.get('OrderCreator')?.depth).toBe(2)
    expect(result.truncated).toBe(false)
  })

  it('detects cycles as back-edges without re-traversing', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 10 })
    const backEdge = result.edges.find(
      (e) => e.from === 'OrderCreator' && e.to === 'CheckoutController',
    )
    expect(backEdge?.isBackEdge).toBe(true)
    expect(result.cycles).toContainEqual(['OrderCreator', 'CheckoutController'])
    // CheckoutController should only appear once at depth 0, not revisited
    expect(result.nodes.get('CheckoutController')?.depth).toBe(0)
  })

  it('filters edges by edgeTypes', () => {
    const result = walk(schema, 'CheckoutController', {
      maxDepth: 10,
      edgeTypes: new Set(['link_to']),
    })
    expect([...result.nodes.keys()].sort()).toEqual(['Cart', 'CheckoutController'])
  })

  it('stops expanding at maxDepth and flags truncated', () => {
    const result = walk(schema, 'CheckoutController', { maxDepth: 1 })
    expect(result.nodes.has('OrderCreator')).toBe(false)
    expect(result.truncated).toBe(true)
  })

  it('returns empty result for unknown entry', () => {
    const result = walk(schema, 'DoesNotExist', { maxDepth: 10 })
    expect(result.nodes.size).toBe(0)
    expect(result.edges).toEqual([])
  })
})
```

- [ ] **Step 5.2: Run the test, confirm it fails**

```
cd frontend/liam-erd/packages/erd-core && pnpm vitest run walker.test.ts
```

Expected: all tests fail with "cannot find module './walker'".

- [ ] **Step 5.3: Implement the walker**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/walker.ts`:

```ts
export type EdgeVia = 'link_to' | 'redirect_to' | 'form_action'

export type WalkableDependency = { target: string; via: string }
export type WalkableNode = { dependencies: WalkableDependency[] }
export type WalkableSchema = { nodes: Record<string, WalkableNode> }

export type WalkOptions = {
  maxDepth?: number
  edgeTypes?: Set<EdgeVia>
}

export type WalkEdge = {
  from: string
  to: string
  via: EdgeVia
  isBackEdge: boolean
}

export type WalkResult = {
  nodes: Map<string, { depth: number }>
  edges: WalkEdge[]
  cycles: Array<[string, string]>
  truncated: boolean
}

const DEFAULT_EDGE_TYPES: Set<EdgeVia> = new Set([
  'link_to',
  'redirect_to',
  'form_action',
])

const DEFAULT_MAX_DEPTH = 10

export function walk(
  schema: WalkableSchema,
  entryId: string,
  opts: WalkOptions = {},
): WalkResult {
  const maxDepth = opts.maxDepth ?? DEFAULT_MAX_DEPTH
  const edgeTypes = opts.edgeTypes ?? DEFAULT_EDGE_TYPES

  const nodes = new Map<string, { depth: number }>()
  const edges: WalkEdge[] = []
  const cycles: Array<[string, string]> = []

  if (!schema.nodes[entryId]) {
    return { nodes, edges, cycles, truncated: false }
  }

  nodes.set(entryId, { depth: 0 })
  const queue: string[] = [entryId]
  let truncated = false

  while (queue.length > 0) {
    const current = queue.shift() as string
    const currentDepth = nodes.get(current)?.depth ?? 0

    const node = schema.nodes[current]
    if (!node) continue

    for (const dep of node.dependencies) {
      if (!isEdgeVia(dep.via) || !edgeTypes.has(dep.via)) continue

      const alreadyVisited = nodes.has(dep.target)

      if (alreadyVisited) {
        edges.push({ from: current, to: dep.target, via: dep.via, isBackEdge: true })
        cycles.push([current, dep.target])
        continue
      }

      if (currentDepth >= maxDepth) {
        truncated = true
        continue
      }

      nodes.set(dep.target, { depth: currentDepth + 1 })
      edges.push({ from: current, to: dep.target, via: dep.via, isBackEdge: false })
      queue.push(dep.target)
    }
  }

  return { nodes, edges, cycles, truncated }
}

function isEdgeVia(value: string): value is EdgeVia {
  return value === 'link_to' || value === 'redirect_to' || value === 'form_action'
}
```

- [ ] **Step 5.4: Run tests, confirm they pass**

```
cd frontend/liam-erd/packages/erd-core && pnpm vitest run walker.test.ts
```

Expected: 6 tests pass.

- [ ] **Step 5.5: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/journey/walker.ts frontend/liam-erd/packages/erd-core/src/features/journey/walker.test.ts
git commit -m "Add pure BFS walker for journey mode"
```

---

## Task 6: Frontend — Journey context and hook

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyContext.tsx`
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.ts`
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.test.tsx`

- [ ] **Step 6.1: Write the failing test**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.test.tsx`:

```tsx
import { describe, expect, it } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { JourneyProvider } from './JourneyContext'
import { useJourneyMode } from './useJourneyMode'
import type { WalkableSchema } from './walker'

const schema: WalkableSchema = {
  nodes: {
    CheckoutController: {
      dependencies: [{ target: 'Cart', via: 'link_to' }],
    },
    Cart: { dependencies: [] },
  },
}

function wrapper(ui: ReactNode) {
  return <JourneyProvider schema={schema}>{ui}</JourneyProvider>
}

describe('useJourneyMode', () => {
  it('is inactive by default', () => {
    const { result } = renderHook(() => useJourneyMode(), {
      wrapper: ({ children }) => wrapper(children),
    })
    expect(result.current.entryPoint).toBeNull()
    expect(result.current.result).toBeNull()
  })

  it('enters journey mode and computes the walk', () => {
    const { result } = renderHook(() => useJourneyMode(), {
      wrapper: ({ children }) => wrapper(children),
    })

    act(() => {
      result.current.enterJourney({
        identifier: 'CheckoutController',
        verb: 'GET',
        path: '/checkout',
        action: 'new',
      })
    })

    expect(result.current.entryPoint?.identifier).toBe('CheckoutController')
    expect(result.current.result?.nodes.has('Cart')).toBe(true)
  })

  it('exits journey mode', () => {
    const { result } = renderHook(() => useJourneyMode(), {
      wrapper: ({ children }) => wrapper(children),
    })

    act(() => {
      result.current.enterJourney({
        identifier: 'CheckoutController',
        verb: 'GET',
        path: '/checkout',
        action: 'new',
      })
    })
    act(() => {
      result.current.exitJourney()
    })

    expect(result.current.entryPoint).toBeNull()
    expect(result.current.result).toBeNull()
  })

  it('re-walks when depth changes', () => {
    const { result } = renderHook(() => useJourneyMode(), {
      wrapper: ({ children }) => wrapper(children),
    })

    act(() => {
      result.current.enterJourney({
        identifier: 'CheckoutController',
        verb: 'GET',
        path: '/checkout',
        action: 'new',
      })
    })
    act(() => {
      result.current.setDepth(0)
    })

    expect(result.current.result?.nodes.size).toBe(1)
    expect(result.current.result?.truncated).toBe(true)
  })
})
```

- [ ] **Step 6.2: Run the test, confirm it fails**

```
cd frontend/liam-erd/packages/erd-core && pnpm vitest run useJourneyMode.test.tsx
```

Expected: all fail with missing module errors.

- [ ] **Step 6.3: Implement the context**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyContext.tsx`:

```tsx
import { createContext, useMemo, useState, type ReactNode } from 'react'
import type { EdgeVia, WalkableSchema, WalkResult } from './walker'
import { walk } from './walker'

export type EntryPoint = {
  identifier: string
  verb: 'GET' | 'SYNTHETIC'
  path: string
  action: string
}

export type JourneyContextValue = {
  entryPoint: EntryPoint | null
  maxDepth: number
  enabledEdgeTypes: Set<EdgeVia>
  result: WalkResult | null
  enterJourney: (entry: EntryPoint) => void
  exitJourney: () => void
  setDepth: (depth: number) => void
  toggleEdgeType: (via: EdgeVia) => void
}

export const JourneyContext = createContext<JourneyContextValue | null>(null)

const DEFAULT_EDGE_TYPES: Set<EdgeVia> = new Set([
  'link_to',
  'redirect_to',
  'form_action',
])

export function JourneyProvider({
  schema,
  children,
}: {
  schema: WalkableSchema
  children: ReactNode
}) {
  const [entryPoint, setEntryPoint] = useState<EntryPoint | null>(null)
  const [maxDepth, setMaxDepth] = useState(10)
  const [enabledEdgeTypes, setEnabledEdgeTypes] =
    useState<Set<EdgeVia>>(DEFAULT_EDGE_TYPES)

  const result = useMemo<WalkResult | null>(() => {
    if (!entryPoint) return null
    return walk(schema, entryPoint.identifier, {
      maxDepth,
      edgeTypes: enabledEdgeTypes,
    })
  }, [schema, entryPoint, maxDepth, enabledEdgeTypes])

  const value: JourneyContextValue = {
    entryPoint,
    maxDepth,
    enabledEdgeTypes,
    result,
    enterJourney: setEntryPoint,
    exitJourney: () => setEntryPoint(null),
    setDepth: setMaxDepth,
    toggleEdgeType: (via) =>
      setEnabledEdgeTypes((prev) => {
        const next = new Set(prev)
        if (next.has(via)) next.delete(via)
        else next.add(via)
        return next
      }),
  }

  return (
    <JourneyContext.Provider value={value}>{children}</JourneyContext.Provider>
  )
}
```

- [ ] **Step 6.4: Implement the hook**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.ts`:

```ts
import { useContext } from 'react'
import { JourneyContext, type JourneyContextValue } from './JourneyContext'

export function useJourneyMode(): JourneyContextValue {
  const ctx = useContext(JourneyContext)
  if (!ctx) {
    throw new Error('useJourneyMode must be used within a JourneyProvider')
  }
  return ctx
}
```

- [ ] **Step 6.5: Run the tests, confirm they pass**

```
cd frontend/liam-erd/packages/erd-core && pnpm vitest run useJourneyMode.test.tsx
```

Expected: 4 tests pass.

- [ ] **Step 6.6: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/journey/JourneyContext.tsx frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.ts frontend/liam-erd/packages/erd-core/src/features/journey/useJourneyMode.test.tsx
git commit -m "Add JourneyContext and useJourneyMode hook"
```

---

## Task 7: Frontend — JourneyBanner component

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyBanner.tsx`
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/journey.module.css`

- [ ] **Step 7.1: Create the CSS module**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/journey.module.css`:

```css
.banner {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 16px;
  background: linear-gradient(180deg, #1c2936, #162029);
  border-bottom: 1px solid #2a3a4a;
  color: #eee;
  font-size: 13px;
}

.badge {
  padding: 2px 8px;
  background: #2a4a6a;
  color: #9cf;
  border-radius: 3px;
  font-weight: 600;
  margin-right: 10px;
}

.meta {
  color: #888;
  margin-left: 10px;
}

.controls {
  display: flex;
  align-items: center;
  gap: 8px;
}

.exitButton {
  padding: 4px 10px;
  background: #222;
  border: 1px solid #444;
  color: #bbb;
  border-radius: 3px;
  font-size: 12px;
  cursor: pointer;
}

.exitButton:hover {
  background: #2a2a2a;
  color: #eee;
}

.legend {
  position: absolute;
  bottom: 12px;
  left: 12px;
  z-index: 10;
  padding: 8px 12px;
  background: rgba(20, 28, 36, 0.92);
  border: 1px solid #2a3a4a;
  border-radius: 4px;
  font-size: 11px;
  color: #aaa;
}

.legendRow {
  display: flex;
  align-items: center;
  gap: 6px;
  margin: 2px 0;
}

:global(.erd-node--outside-journey) {
  opacity: 0.4;
}

:global(.erd-node--journey-entry) {
  outline: 2px solid #4a8acf;
  box-shadow: 0 0 16px rgba(74, 138, 207, 0.4);
}

:global(.erd-edge--link_to) {
  stroke-dasharray: none;
  stroke-width: 1.5;
}

:global(.erd-edge--redirect_to) {
  stroke-dasharray: 4 4;
  stroke-width: 1.5;
}

:global(.erd-edge--form_action) {
  stroke-dasharray: none;
  stroke-width: 3;
}

:global(.erd-edge--back-edge) {
  opacity: 0.5;
}
```

- [ ] **Step 7.2: Create the banner component**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyBanner.tsx`:

```tsx
import { useJourneyMode } from './useJourneyMode'
import styles from './journey.module.css'
import type { EdgeVia } from './walker'

const EDGE_TYPES: EdgeVia[] = ['link_to', 'redirect_to', 'form_action']

export function JourneyBanner() {
  const {
    entryPoint,
    maxDepth,
    enabledEdgeTypes,
    result,
    exitJourney,
    setDepth,
    toggleEdgeType,
  } = useJourneyMode()

  if (!entryPoint || !result) return null

  const label =
    entryPoint.verb === 'GET'
      ? `${entryPoint.verb} ${entryPoint.path} → ${entryPoint.identifier}#${entryPoint.action}`
      : `Journey from ${entryPoint.identifier}`

  return (
    <div className={styles.banner} role="region" aria-label="Journey mode banner">
      <div>
        <span className={styles.badge}>JOURNEY</span>
        <span>{label}</span>
        <span className={styles.meta}>
          reaches {result.nodes.size} nodes · depth {maxDepth}
          {result.truncated && ' (truncated)'}
        </span>
      </div>
      <div className={styles.controls}>
        <label>
          Depth:
          <select
            value={maxDepth}
            onChange={(e) => setDepth(Number(e.target.value))}
            aria-label="Walk depth"
          >
            {Array.from({ length: 10 }, (_, i) => i + 1).map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
        </label>
        {EDGE_TYPES.map((via) => (
          <label key={via}>
            <input
              type="checkbox"
              checked={enabledEdgeTypes.has(via)}
              onChange={() => toggleEdgeType(via)}
            />
            {via}
          </label>
        ))}
        <button
          type="button"
          className={styles.exitButton}
          onClick={exitJourney}
        >
          Exit journey
        </button>
      </div>
    </div>
  )
}
```

- [ ] **Step 7.3: Verify the module compiles**

```
cd frontend/liam-erd/packages/erd-core && pnpm tsc --noEmit
```

Expected: no errors in the journey directory.

- [ ] **Step 7.4: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/journey/JourneyBanner.tsx frontend/liam-erd/packages/erd-core/src/features/journey/journey.module.css
git commit -m "Add JourneyBanner component and CSS module"
```

---

## Task 8: Frontend — JourneyLegend component + module barrel

**Files:**
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyLegend.tsx`
- Create: `frontend/liam-erd/packages/erd-core/src/features/journey/index.ts`

- [ ] **Step 8.1: Create the legend**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/JourneyLegend.tsx`:

```tsx
import { useJourneyMode } from './useJourneyMode'
import styles from './journey.module.css'

export function JourneyLegend() {
  const { entryPoint } = useJourneyMode()
  if (!entryPoint) return null

  return (
    <div className={styles.legend} role="note" aria-label="Edge type legend">
      <div style={{ marginBottom: 4, fontWeight: 600, color: '#ddd' }}>
        Edge types
      </div>
      <div className={styles.legendRow}>
        <span
          style={{ display: 'inline-block', width: 24, borderTop: '2px solid #4a8acf' }}
        />
        link_to
      </div>
      <div className={styles.legendRow}>
        <span
          style={{ display: 'inline-block', width: 24, borderTop: '2px dashed #cf8a4a' }}
        />
        redirect_to
      </div>
      <div className={styles.legendRow}>
        <span
          style={{ display: 'inline-block', width: 24, borderTop: '3px solid #8a4acf' }}
        />
        form_action
      </div>
    </div>
  )
}
```

- [ ] **Step 8.2: Create the barrel**

Create `frontend/liam-erd/packages/erd-core/src/features/journey/index.ts`:

```ts
export { JourneyProvider, JourneyContext } from './JourneyContext'
export type { EntryPoint, JourneyContextValue } from './JourneyContext'
export { useJourneyMode } from './useJourneyMode'
export { JourneyBanner } from './JourneyBanner'
export { JourneyLegend } from './JourneyLegend'
export { walk } from './walker'
export type {
  EdgeVia,
  WalkResult,
  WalkOptions,
  WalkableSchema,
} from './walker'
```

- [ ] **Step 8.3: Verify compile**

```
cd frontend/liam-erd/packages/erd-core && pnpm tsc --noEmit
```

Expected: no errors.

- [ ] **Step 8.4: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/journey/JourneyLegend.tsx frontend/liam-erd/packages/erd-core/src/features/journey/index.ts
git commit -m "Add JourneyLegend component and module barrel"
```

---

## Task 9: Frontend — Mount JourneyProvider + banner + legend

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx`

- [ ] **Step 9.1: Read the current renderer to locate the mount point**

```
head -80 frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx
```

Identify:
- Where the schema is passed in (prop or hook — capture the exact prop/variable name).
- The outer container JSX where a provider can wrap and where banner + legend can absolute-position.

- [ ] **Step 9.2: Wrap the renderer**

In `ErdRenderer.tsx`:

1. Add the import at the top with the other feature imports:

```tsx
import { JourneyProvider, JourneyBanner, JourneyLegend } from '../../../journey'
```

2. Find the outermost JSX fragment/element that contains the React Flow canvas and wrap it in `<JourneyProvider schema={schema}>`. Inside the provider, directly inside the canvas container (which should be `position: relative` — it already is if ELK layout works), add:

```tsx
<JourneyBanner />
<JourneyLegend />
```

Both components self-gate on `entryPoint` being set, so they render nothing when journey mode is inactive.

The exact wrapping pattern depends on the current JSX — the principle is: `schema` must be in scope, provider wraps the canvas, banner + legend render as absolutely-positioned siblings of the canvas (not inside React Flow's internal root).

- [ ] **Step 9.3: Verify compile**

```
cd frontend/liam-erd/packages/erd-core && pnpm tsc --noEmit
```

Expected: no errors.

- [ ] **Step 9.4: Boot the dev server and sanity-check**

```
cd frontend/liam-erd/packages/cli && pnpm dev
```

Open the ERD in a browser. The page should render exactly as before — no visible change. If anything rendered, something's wrong with the self-gating.

- [ ] **Step 9.5: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/ErdRenderer.tsx
git commit -m "Mount JourneyProvider and overlay components in ErdRenderer"
```

---

## Task 10: Frontend — Apply journey classes to nodes and edges

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/` (exact file determined by inspection — likely `ERDContent.tsx` or `index.tsx`)

- [ ] **Step 10.1: Locate the node + edge rendering code**

```
ls frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/
grep -rn "nodeTypes\|edgeTypes\|<ReactFlow" frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/ 2>/dev/null | head -10
```

Identify the file that renders `<ReactFlow>` and the per-node/per-edge className site.

- [ ] **Step 10.2: Read the `useJourneyMode` hook from inside that component**

Add the import at the top of the identified file:

```tsx
import { useJourneyMode } from '../../../journey'
```

Inside the component body, call:

```tsx
const { entryPoint, result } = useJourneyMode()
```

- [ ] **Step 10.3: Compute derived sets**

Right after the hook call:

```tsx
const journeyNodeIds = useMemo(
  () => (result ? new Set(result.nodes.keys()) : null),
  [result],
)
```

Add `useMemo` to the React import at the top of the file if not already present.

- [ ] **Step 10.4: Apply node className**

Where the component builds the `nodes` array for React Flow (or provides per-node styling), add a `className` field that combines the existing className with the journey classes:

```tsx
const journeyClass =
  !journeyNodeIds
    ? ''
    : journeyNodeIds.has(node.id)
      ? node.id === entryPoint?.identifier
        ? 'erd-node--journey-entry'
        : ''
      : 'erd-node--outside-journey'

return {
  ...node,
  className: [node.className, journeyClass].filter(Boolean).join(' '),
}
```

Place this inside whatever `.map` currently produces React Flow nodes. If nodes are built in a helper function outside the component, pass `journeyNodeIds` and `entryPoint` as arguments.

- [ ] **Step 10.5: Apply edge className**

Same file, where edges are built. For each edge:

```tsx
const viaClass = edge.data?.via ? `erd-edge--${edge.data.via}` : ''
const backEdgeClass =
  result?.edges.find(
    (e) => e.from === edge.source && e.to === edge.target && e.isBackEdge,
  )
    ? 'erd-edge--back-edge'
    : ''

return {
  ...edge,
  className: [edge.className, viaClass, backEdgeClass].filter(Boolean).join(' '),
}
```

If edges don't currently carry `via` in `data`, you'll need to add it at the point where edges are constructed from `schema.nodes[*].dependencies` — locate that code and include `via` in `edge.data`.

- [ ] **Step 10.6: Verify compile**

```
cd frontend/liam-erd/packages/erd-core && pnpm tsc --noEmit
```

Expected: no errors.

- [ ] **Step 10.7: Manual smoke test**

Boot the dev server again. The ERD should render normally with no journey mode active. No visual regressions.

- [ ] **Step 10.8: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/
git commit -m "Apply journey CSS classes to nodes and edges"
```

---

## Task 11: Frontend — Entry Points section in ⌘K palette

**Files:**
- Modify: `frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPalette.tsx`

- [ ] **Step 11.1: Read the existing palette structure**

```
cat frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPalette.tsx
```

Identify:
- The existing `<Command.Group heading="...">` blocks.
- How the list of suggestions is sourced (hook, prop, context).
- How selection is wired up (`onSelect` per item).

- [ ] **Step 11.2: Import dependencies**

Add to the top of `CommandPalette.tsx`:

```tsx
import { useJourneyMode } from '../../../../journey'
import type { EntryPoint } from '../../../../journey'
```

Also ensure the schema's `EntryPoint` type is available. If the component receives `schema` as a prop, access `schema.entryPoints ?? []`. If the component pulls schema from a hook/context, find that source and use it the same way.

- [ ] **Step 11.3: Render the Entry Points group**

Inside the palette's result list, **before** the existing `<Command.Group heading="Nodes">`, add:

```tsx
{(schema.entryPoints ?? []).length > 0 && (
  <Command.Group heading="Entry Points">
    {(schema.entryPoints ?? []).map((entry) => (
      <Command.Item
        key={`entry-${entry.identifier}-${entry.path}`}
        value={`${entry.verb} ${entry.path} ${entry.identifier} ${entry.action}`}
        onSelect={() => {
          enterJourney({
            identifier: entry.identifier,
            verb: 'GET',
            path: entry.path,
            action: entry.action,
          })
          onClose()
        }}
      >
        <span>
          {entry.verb} {entry.path} → {entry.identifier}#{entry.action}
        </span>
      </Command.Item>
    ))}
  </Command.Group>
)}
```

Inside the component body, add:

```tsx
const { enterJourney } = useJourneyMode()
```

Adjust `onClose` to match whatever the existing close mechanism is named (e.g., `setOpen(false)` or a prop-passed handler). The pattern of "select → enter journey → close palette" is the required behavior — match it to the existing palette's idiom.

- [ ] **Step 11.4: Verify compile**

```
cd frontend/liam-erd/packages/erd-core && pnpm tsc --noEmit
```

Expected: no errors.

- [ ] **Step 11.5: Manual smoke test**

Boot the dev server. Press ⌘K — you should see an "Entry Points" section listing GET routes. Select one; the journey banner should appear.

- [ ] **Step 11.6: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDRenderer/CommandPalette/CommandPalette.tsx
git commit -m "Add Entry Points section to command palette"
```

---

## Task 12: Frontend — Right-click "Start journey from here"

**Files:**
- Modify: whichever file inside `ERDContent/` renders node context menus (locate by grepping for existing `onContextMenu`, `nodeContextMenu`, or similar).

- [ ] **Step 12.1: Locate the existing context-menu logic**

```
grep -rn "onContextMenu\|ContextMenu\|contextmenu" frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent 2>/dev/null
```

If a context menu component/hook already exists, you'll extend it. If not, a minimal addition is a React Flow `onNodeContextMenu` handler that opens a small floating menu — do the minimum required; don't refactor existing patterns.

- [ ] **Step 12.2: Add the menu item**

Extend the existing context menu (or build the minimal addition) with a single item:

```tsx
{node.type === 'woods-controller' && (
  <button
    type="button"
    onClick={() => {
      enterJourney({
        identifier: node.id,
        verb: 'SYNTHETIC',
        path: '',
        action: '',
      })
      closeMenu()
    }}
  >
    Start journey from here
  </button>
)}
```

Adjust the `node.type === 'woods-controller'` check to match whatever discriminator the codebase uses to identify controllers. Import `useJourneyMode` from `'../../../../journey'` and call `const { enterJourney } = useJourneyMode()` inside the component.

- [ ] **Step 12.3: Verify compile**

```
cd frontend/liam-erd/packages/erd-core && pnpm tsc --noEmit
```

Expected: no errors.

- [ ] **Step 12.4: Manual smoke test**

Boot the dev server. Right-click a controller node — the menu should show "Start journey from here"; selecting it opens journey mode with a synthetic banner (`Journey from <Controller>`).

- [ ] **Step 12.5: Commit**

```
git add frontend/liam-erd/packages/erd-core/src/features/erd/components/ERDContent/
git commit -m "Add 'Start journey from here' context menu item on controllers"
```

---

## Task 13: Rebuild vendor assets and end-to-end verify

**Files:**
- Modify: `vendor/assets/liam-erd/` (regenerated build output)

- [ ] **Step 13.1: Build the frontend**

```
cd frontend/liam-erd/packages/cli && pnpm build
```

Expected: build succeeds; the new bundle hash is printed.

- [ ] **Step 13.2: Copy build output into vendor**

Check the gem's existing vendor-sync mechanism first:

```
grep -rn "vendor/assets/liam-erd" Rakefile lib/ bin/ 2>/dev/null | head
```

If there's a rake task that syncs the build output, run it. Otherwise, copy the contents of `frontend/liam-erd/packages/cli/dist/` into `vendor/assets/liam-erd/` and update `vendor/assets/liam-erd/index.html` to reference the new bundle filename.

- [ ] **Step 13.3: Run the full gem spec suite**

```
bundle exec rake spec
```

Expected: 0 failures.

- [ ] **Step 13.4: Run all frontend tests**

```
cd frontend/liam-erd && pnpm -r test
```

Expected: 0 failures across all packages.

- [ ] **Step 13.5: Run rubocop**

```
bundle exec rubocop
```

Expected: no offenses.

- [ ] **Step 13.6: End-to-end manual smoke test**

Start the ERD server against a host Rails app with extracted data. Verify each acceptance criterion from the spec (Section 6):

1. `schema.json` contains `entryPoints`.
2. ERD renders unchanged when journey mode is inactive.
3. ⌘K shows "Entry Points" section; selecting enters journey mode.
4. Right-click on a controller shows "Start journey from here".
5. Journey mode shows banner + dimmed non-journey nodes + three edge styles + back-edge opacity.
6. Depth dropdown updates the visible subgraph without re-layout.
7. Exit journey restores full-color rendering.
8. Walker unit tests cover BFS/depth/cycles/edge-type filter.
9. No regressions in existing ERD functionality.

- [ ] **Step 13.7: Commit**

```
git add vendor/assets/liam-erd/
git commit -m "Rebuild vendor ERD assets with journey mode"
```

---

## Self-Review Checklist (completed before handoff)

- **Spec coverage:** All six spec sections have at least one task (Section 1 → Tasks 1–3; Section 2 → Tasks 5–12; Section 3 → Task 4; Section 4 → file inventory matches; Section 5 risks are mitigated in-task; Section 6 acceptance criteria verified in Task 13.6).
- **Placeholder scan:** No TBDs, TODOs, "handle edge cases", or "similar to Task N" phrasing. Code blocks appear in every code step.
- **Type consistency:** `EntryPoint`, `WalkResult`, `WalkableSchema`, `EdgeVia`, `JourneyContextValue` appear with identical shapes across all tasks. `enterJourney` signature is consistent (single `EntryPoint` argument) in Tasks 6, 11, 12.
