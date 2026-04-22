# User Journey v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Journey/Explore mode split from `docs/superpowers/specs/2026-04-22-user-journey-v2-design.md` — fix the entryPoints palette bug, make Journey a dedicated mode that snapshots/restores Explore state, add a Navigation edges toolbar toggle, and simplify the banner.

**Architecture:** v1 of journey mode (walker, entry-point index, JourneyContext, JourneyBanner, JourneyLegend, EntryPointOptions, right-click menu) already exists. This plan modifies existing files to: (a) diagnose and fix the runtime bug where `schema.current.entryPoints` is undefined in the browser, (b) extend JourneyContext with snapshot/restore of `{showMode, hiddenNodeIds, activeTableName, viewport}`, (c) subscribe ShowModeMenu and ErdContent to `journeyActive`, (d) add a single-checkbox toolbar action for Navigation edges in Explore mode, (e) strip edge-type checkboxes from JourneyBanner.

**Tech Stack:** TypeScript, React, Vite, Valibot, React Flow (`@xyflow/react`), Vitest, cmdk. CSS Modules. Monorepo with pnpm workspaces.

**Key file map:**
- `packages/schema/src/schema/schema.ts` — Valibot `entryPointSchema` (already present).
- `packages/cli/src/App.tsx` — fetches and parses `schema.json`; silent `console.info(result.issues)` on parse failure.
- `packages/erd-core/src/features/journey/JourneyContext.tsx` — provider to extend with snapshot state.
- `packages/erd-core/src/features/journey/useJourneyMode.ts` — `enterJourney` / `exitJourney` to augment.
- `packages/erd-core/src/features/journey/JourneyBanner.tsx` — strip edge-type checkboxes.
- `packages/erd-core/src/stores/userEditing/context.ts` + `hooks.ts` — source of `showMode`, `hiddenNodeIds`, `activeTableName`; add `navigationEdgesVisible`.
- `packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/DesktopToolbar.tsx` — add Navigation edges toggle.
- `packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/ShowModeMenu/ShowModeMenu.tsx` — disabled state while journey active.
- `packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx` — filter to walked subgraph + include nav edges when toggle on.
- `packages/erd-core/src/features/journey/journey.module.css` — remove `.erd-node--outside-journey` dim style.

**Test command base (run from `frontend/liam-erd/`):**
```
pnpm --filter @liam-hq/schema test -- --run
pnpm --filter @liam-hq/erd-core test -- --run
```

Add `--reporter=verbose` when debugging single tests. Use `pnpm --filter ... test -- --run <file>` to target one file.

---

### Task 1: Diagnose the entryPoints runtime disappearance

The Valibot schema already defines `entryPoints` (`packages/schema/src/schema/schema.ts:169`). The backend emits matching shape (`{ identifier, verb: 'GET', path, action }`). Yet the browser reports `schema.current.entryPoints` as undefined. Something between the fetch and the context drops it. Before fixing, capture the real failure.

**Files:**
- Read: `packages/cli/src/App.tsx:20-39`
- Read: `packages/schema/src/schema/schema.ts:150-172`
- Read: backend output at whatever path serves `schema.json` in the smoke testbed

- [ ] **Step 1: Reproduce in the smoke testbed**

Run the testbed per `docs/TESTBED.md`. Open the ERD in a browser with DevTools Console open. Trigger ⌘K and type an entry-point match (e.g., a known controller name). Confirm the Entry Points group does not render.

- [ ] **Step 2: Capture the Valibot issues log**

In DevTools Console, locate output from `packages/cli/src/App.tsx:36` (`console.info(result.issues)`). If there are issues, they describe the exact parse failure. Copy them verbatim. If there is no such log, `result.success` is true — meaning entryPoints survives parsing but is dropped downstream.

- [ ] **Step 3: Inspect the parsed result directly**

In DevTools Console, run:
```js
fetch('./schema.json').then(r => r.json()).then(d => { window.__rawSchema = d; console.log('entryPoints count:', d.entryPoints?.length); console.log('first 2:', d.entryPoints?.slice(0,2)); })
```

If count is 0 or undefined: backend issue (the route to `schema.json` served by Rails is not emitting it — check what's serving the endpoint the ERD hits; it may differ from `/woods/erd/schema.json`).

If count is >0 but `schema.current.entryPoints` is still undefined in React DevTools on `SchemaContext.Provider`: Valibot is dropping the field. Likely one entry fails `entryPointSchema`, which — because `entryPoints` is in the parent schema — fails the whole parent parse.

- [ ] **Step 4: Write the root-cause findings to the plan**

Edit this file (`docs/superpowers/plans/2026-04-22-user-journey-v2.md`) and add a `Task 1 findings:` block at the end of this task listing: (a) count of entryPoints in the raw response, (b) whether `v.safeParse` succeeded, (c) the first issue message if it failed, (d) the root cause. Commit.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-04-22-user-journey-v2.md
git commit -m "Diagnose journey v2 Bug 1 (entryPoints runtime dropout)"
```

---

### Task 2: Fix the entryPoints runtime bug

Scope depends on Task 1 findings. Two common outcomes with their fixes below; pick the one that matches.

**Files (both outcomes):**
- Test: `packages/schema/src/schema/schema.test.ts`

- [ ] **Step 1: Write the failing regression test**

Use a fixture that mirrors what the backend emits in the reproduction. Add to `schema.test.ts`:

```ts
it('preserves entryPoints through safeParse when backend shape is exactly as emitted', () => {
  const raw = {
    tables: {},
    enums: {},
    extensions: {},
    entryPoints: [
      { identifier: 'StaticPagesController', verb: 'GET', path: '/contact', action: 'contact' },
    ],
  }
  const result = v.safeParse(schemaSchema, raw)
  expect(result.success).toBe(true)
  if (result.success) {
    expect(result.output.entryPoints).toHaveLength(1)
    expect(result.output.entryPoints?.[0]?.identifier).toBe('StaticPagesController')
  }
})
```

If Task 1 revealed an actual failing entry (e.g., a missing field, a verb not equal to 'GET', a stray field), add a second test using that exact shape.

- [ ] **Step 2: Run the test to confirm baseline**

```
pnpm --filter @liam-hq/schema test -- --run schema.test.ts
```

Expected: the synthetic test passes (if it fails, the schema module itself is broken — that becomes the fix target). The diagnostic-mirrored test either passes (meaning the bug is not in schema parsing) or fails (meaning it is).

- [ ] **Step 3: Apply the fix**

**Outcome A — backend emits a malformed entry.** Fix `lib/woods/erd/entry_point_index_builder.rb` to produce a consistent shape (e.g., coerce nil fields to empty strings, or skip entries lacking required fields). Add RSpec coverage.

**Outcome B — Valibot schema is stricter than the backend shape.** Loosen the offending field (e.g., widen `verb: v.literal('GET')` to `verb: v.picklist(['GET'])` if that's not the issue; or accept an extra field the backend emits but the schema doesn't allow — Valibot's default is to error on unknown fields only if the schema is `v.strictObject`; confirm current behaviour before changing).

**Outcome C — the endpoint the ERD fetches isn't `schema.json`.** The CLI fetches `./schema.json` relative to itself. If Rails serves the ERD from a path that masks `schema.json` with a different file, fix the Rails mount. Out-of-scope if it's purely a Rails routing issue; split to a separate task.

- [ ] **Step 4: Re-run the test to confirm pass**

```
pnpm --filter @liam-hq/schema test -- --run schema.test.ts
```

Expected: PASS.

- [ ] **Step 5: Manual verification in the testbed**

Rebuild the CLI (`pnpm --filter @liam-hq/cli build`), reload the ERD. Confirm the Entry Points group appears in ⌘K when the search matches a known entry point.

- [ ] **Step 6: Commit**

```bash
git add packages/schema/src/schema/schema.test.ts <other modified files>
git commit -m "Fix entryPoints dropout so ⌘K shows Entry Points group"
```

---

### Task 3: Add snapshot fields to UserEditing context

Journey v2 needs to snapshot `{showMode, hiddenNodeIds, activeTableName, viewport}` on entry and restore on exit. The first three live in `UserEditingContext`; the viewport lives in React Flow. This task adds `navigationEdgesVisible` as a new flag (for Task 9) and nothing else.

**Files:**
- Modify: `packages/erd-core/src/stores/userEditing/context.ts`
- Modify: `packages/erd-core/src/stores/userEditing/UserEditingProvider.tsx` (whichever file provides the default state; check via `grep -rn "UserEditingContext.Provider"`)
- Test: `packages/erd-core/src/stores/userEditing/userEditing.test.tsx` (create if absent)

- [ ] **Step 1: Write failing test for navigationEdgesVisible default and toggle**

Create or extend `packages/erd-core/src/stores/userEditing/userEditing.test.tsx`:

```tsx
import { renderHook, act } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { useUserEditingOrThrow } from './hooks'
import { UserEditingProvider } from './UserEditingProvider' // adjust import path to the actual provider

describe('UserEditingContext navigationEdgesVisible', () => {
  it('defaults to false', () => {
    const { result } = renderHook(() => useUserEditingOrThrow(), {
      wrapper: ({ children }) => <UserEditingProvider>{children}</UserEditingProvider>,
    })
    expect(result.current.navigationEdgesVisible).toBe(false)
  })

  it('toggles via setNavigationEdgesVisible', () => {
    const { result } = renderHook(() => useUserEditingOrThrow(), {
      wrapper: ({ children }) => <UserEditingProvider>{children}</UserEditingProvider>,
    })
    act(() => result.current.setNavigationEdgesVisible(true))
    expect(result.current.navigationEdgesVisible).toBe(true)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

```
pnpm --filter @liam-hq/erd-core test -- --run userEditing
```

Expected: FAIL with `navigationEdgesVisible is undefined`.

- [ ] **Step 3: Add the field to the context type**

Edit `packages/erd-core/src/stores/userEditing/context.ts` — inside `UserEditingContextValue`, add:

```ts
navigationEdgesVisible: boolean
setNavigationEdgesVisible: (visible: boolean) => void
```

Add it at the bottom of the type (maintain existing ordering for readability).

- [ ] **Step 4: Add the state to the provider**

In the provider file, add `useState<boolean>(false)` for `navigationEdgesVisible`, destructure it and the setter into the `value`:

```tsx
const [navigationEdgesVisible, setNavigationEdgesVisible] = useState(false)
// ...within value={...}:
navigationEdgesVisible,
setNavigationEdgesVisible,
```

- [ ] **Step 5: Run test to verify it passes**

```
pnpm --filter @liam-hq/erd-core test -- --run userEditing
```

Expected: PASS (both cases).

- [ ] **Step 6: Commit**

```bash
git add packages/erd-core/src/stores/userEditing/context.ts packages/erd-core/src/stores/userEditing/UserEditingProvider.tsx packages/erd-core/src/stores/userEditing/userEditing.test.tsx
git commit -m "Add navigationEdgesVisible to UserEditing context"
```

---

### Task 4: Snapshot Explore state on journey enter

Extend `JourneyContext` with a `snapshot` ref that captures `{showMode, hiddenNodeIds, activeTableName, viewport}` at the moment `enterJourney` is called.

**Files:**
- Modify: `packages/erd-core/src/features/journey/JourneyContext.tsx`
- Modify: `packages/erd-core/src/features/journey/useJourneyMode.ts`
- Test: `packages/erd-core/src/features/journey/useJourneyMode.test.tsx`

- [ ] **Step 1: Write failing test**

Append to `useJourneyMode.test.tsx`:

```tsx
it('snapshots showMode and activeTableName on enterJourney', () => {
  const { result } = renderHook(
    () => ({ journey: useJourneyMode(), user: useUserEditingOrThrow() }),
    { wrapper: AllProvidersWrapper }, // use the existing test wrapper
  )
  act(() => {
    result.current.user.setShowMode('TABLE_NAME')
    result.current.user.setActiveTableName('users')
  })
  act(() => {
    result.current.journey.enterJourney({
      identifier: 'StaticPagesController',
      verb: 'GET',
      path: '/contact',
      action: 'contact',
    })
  })
  expect(result.current.journey.snapshot).toEqual({
    showMode: 'TABLE_NAME',
    activeTableName: 'users',
    hiddenNodeIds: [],
    // viewport tested separately; omitted here
  })
})
```

Adjust `'TABLE_NAME'` to whatever `ShowMode` value the existing code uses — check `packages/erd-core/src/schemas/showMode.ts` or similar.

- [ ] **Step 2: Run test to verify it fails**

```
pnpm --filter @liam-hq/erd-core test -- --run useJourneyMode
```

Expected: FAIL with `snapshot` undefined.

- [ ] **Step 3: Extend JourneyContext with snapshot state**

In `JourneyContext.tsx`, add to the context value shape:

```ts
type ExploreSnapshot = {
  showMode: ShowMode
  hiddenNodeIds: string[]
  activeTableName: string | null
  viewport: { x: number; y: number; zoom: number } | null
}

// Inside JourneyContextValue:
snapshot: ExploreSnapshot | null
```

In the provider, add `const [snapshot, setSnapshot] = useState<ExploreSnapshot | null>(null)`.

- [ ] **Step 4: Populate snapshot in enterJourney**

In `useJourneyMode.ts`, expose a setter or call `setSnapshot` inline. `enterJourney` now reads from `UserEditingContext`:

```ts
const enterJourney = useCallback((entry: EntryPoint) => {
  const snap: ExploreSnapshot = {
    showMode: userEditing.showMode,
    hiddenNodeIds: userEditing.hiddenNodeIds,
    activeTableName: userEditing.activeTableName,
    viewport: null, // filled in Task 7
  }
  setSnapshot(snap)
  setEntryPoint(entry)
}, [userEditing.showMode, userEditing.hiddenNodeIds, userEditing.activeTableName, setSnapshot, setEntryPoint])
```

- [ ] **Step 5: Run test to verify it passes**

```
pnpm --filter @liam-hq/erd-core test -- --run useJourneyMode
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/erd-core/src/features/journey/JourneyContext.tsx packages/erd-core/src/features/journey/useJourneyMode.ts packages/erd-core/src/features/journey/useJourneyMode.test.tsx
git commit -m "Snapshot Explore state on enterJourney"
```

---

### Task 5: Restore Explore state on journey exit

`exitJourney` resets `entryPoint` today. It must also apply the snapshot back to UserEditingContext, then clear the snapshot.

**Files:**
- Modify: `packages/erd-core/src/features/journey/useJourneyMode.ts`
- Test: `packages/erd-core/src/features/journey/useJourneyMode.test.tsx`

- [ ] **Step 1: Write failing test**

```tsx
it('restores showMode and activeTableName on exitJourney', () => {
  const { result } = renderHook(
    () => ({ journey: useJourneyMode(), user: useUserEditingOrThrow() }),
    { wrapper: AllProvidersWrapper },
  )
  act(() => {
    result.current.user.setShowMode('TABLE_NAME')
    result.current.user.setActiveTableName('users')
  })
  act(() => {
    result.current.journey.enterJourney({ identifier: 'X', verb: 'GET', path: '/x', action: 'show' })
  })
  act(() => {
    result.current.user.setShowMode('ALL_FIELDS')
    result.current.user.setActiveTableName(null)
  })
  act(() => {
    result.current.journey.exitJourney()
  })
  expect(result.current.user.showMode).toBe('TABLE_NAME')
  expect(result.current.user.activeTableName).toBe('users')
  expect(result.current.journey.entryPoint).toBeNull()
  expect(result.current.journey.snapshot).toBeNull()
})
```

- [ ] **Step 2: Run test to verify it fails**

```
pnpm --filter @liam-hq/erd-core test -- --run useJourneyMode
```

Expected: FAIL.

- [ ] **Step 3: Implement restore in exitJourney**

```ts
const exitJourney = useCallback(() => {
  if (snapshot) {
    userEditing.setShowMode(snapshot.showMode)
    userEditing.setHiddenNodeIds(snapshot.hiddenNodeIds)
    userEditing.setActiveTableName(snapshot.activeTableName)
    // viewport restore happens in Task 7
  }
  setEntryPoint(null)
  setSnapshot(null)
}, [snapshot, userEditing.setShowMode, userEditing.setHiddenNodeIds, userEditing.setActiveTableName, setEntryPoint, setSnapshot])
```

- [ ] **Step 4: Run test to verify it passes**

```
pnpm --filter @liam-hq/erd-core test -- --run useJourneyMode
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/erd-core/src/features/journey/useJourneyMode.ts packages/erd-core/src/features/journey/useJourneyMode.test.tsx
git commit -m "Restore Explore state on exitJourney"
```

---

### Task 6: Auto-exit Focus mode on journey enter

Focus mode in this codebase is driven by `activeTableName`. When a journey begins, clear it so the canvas doesn't stay pinned on a focused node while the banner claims a different entry point.

**Files:**
- Modify: `packages/erd-core/src/features/journey/useJourneyMode.ts`
- Modify: `packages/erd-core/src/features/journey/useJourneyMode.test.tsx`

- [ ] **Step 1: Write failing test**

```tsx
it('clears activeTableName on enterJourney (auto-exit Focus)', () => {
  const { result } = renderHook(
    () => ({ journey: useJourneyMode(), user: useUserEditingOrThrow() }),
    { wrapper: AllProvidersWrapper },
  )
  act(() => result.current.user.setActiveTableName('users'))
  act(() => result.current.journey.enterJourney({ identifier: 'X', verb: 'GET', path: '/x', action: 'show' }))
  expect(result.current.user.activeTableName).toBeNull()
})
```

- [ ] **Step 2: Run test to verify it fails**

```
pnpm --filter @liam-hq/erd-core test -- --run useJourneyMode
```

Expected: FAIL.

- [ ] **Step 3: Add clear call in enterJourney**

In `enterJourney` (the one edited in Task 4), AFTER `setSnapshot(snap)` and BEFORE `setEntryPoint(entry)`, add:

```ts
userEditing.setActiveTableName(null)
```

- [ ] **Step 4: Run test to verify it passes**

```
pnpm --filter @liam-hq/erd-core test -- --run useJourneyMode
```

Expected: PASS. Also re-run the Task 5 restore test to make sure the snapshot still captures the pre-enter `activeTableName`.

- [ ] **Step 5: Commit**

```bash
git add packages/erd-core/src/features/journey/useJourneyMode.ts packages/erd-core/src/features/journey/useJourneyMode.test.tsx
git commit -m "Auto-exit Focus mode when entering journey"
```

---

### Task 7: Snapshot and restore viewport via React Flow

Journey should auto-frame the walked subgraph on enter and restore the previous viewport on exit.

**Files:**
- Modify: `packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx`
- Read: `packages/erd-core/src/features/erd/components/ERDContent/` for existing ReactFlow wiring

- [ ] **Step 1: Find the ReactFlow instance**

`grep -n "useReactFlow\|ReactFlow" packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx` — identify where `useReactFlow()` is called (or add it near the top if absent). The instance provides `getViewport()`, `setViewport()`, `fitView()`.

- [ ] **Step 2: Add a useEffect that reacts to journey state**

Add to `ErdContent.tsx` (before the return):

```tsx
const reactFlow = useReactFlow()
const journey = useContext(JourneyContext) // null-safe; context may be absent outside JourneyProvider

useEffect(() => {
  if (!journey) return
  if (journey.entryPoint && !journey.snapshot?.viewport) {
    // Just entered: capture current viewport, then fit to subgraph
    journey.setSnapshotViewport(reactFlow.getViewport())
    const walkedIds = Array.from(journey.result?.nodes.keys() ?? [])
    if (walkedIds.length > 0) {
      reactFlow.fitView({ nodes: walkedIds.map(id => ({ id })), duration: 400, padding: 0.2 })
    }
  }
  if (!journey.entryPoint && journey.snapshot?.viewport) {
    // Just exited: restore saved viewport
    reactFlow.setViewport(journey.snapshot.viewport, { duration: 400 })
  }
}, [journey?.entryPoint, journey?.snapshot, reactFlow])
```

This requires `JourneyContext` to expose a `setSnapshotViewport` setter — add it in the provider:

```ts
const setSnapshotViewport = useCallback((vp: {x:number; y:number; zoom:number}) => {
  setSnapshot(prev => prev ? { ...prev, viewport: vp } : prev)
}, [setSnapshot])
```

- [ ] **Step 3: Write a Vitest that stubs useReactFlow and asserts fitView is called**

Vitest doesn't natively render ReactFlow. Use a mock:

```tsx
vi.mock('@xyflow/react', async () => {
  const actual = await vi.importActual<typeof import('@xyflow/react')>('@xyflow/react')
  return { ...actual, useReactFlow: () => ({ getViewport: () => ({ x: 10, y: 20, zoom: 1 }), setViewport: vi.fn(), fitView: vi.fn() }) }
})
```

Then test that mounting ErdContent with a set `entryPoint` calls `fitView` with the walked node IDs. (If the test infrastructure doesn't support this cleanly, skip this step and rely on manual smoke-test verification — document the gap in the commit message.)

- [ ] **Step 4: Manually verify in the testbed**

Enter a journey from ⌘K. Confirm the canvas auto-frames on the walk. Exit. Confirm the canvas restores the previous viewport.

- [ ] **Step 5: Commit**

```bash
git add packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx packages/erd-core/src/features/journey/JourneyContext.tsx <test file>
git commit -m "Auto-frame journey subgraph; restore viewport on exit"
```

---

### Task 8: Disable ShowModeMenu while journey is active

**Files:**
- Modify: `packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/ShowModeMenu/ShowModeMenu.tsx`
- Read: that file first to identify the root trigger element

- [ ] **Step 1: Subscribe to JourneyContext**

At the top of `ShowModeMenu`:

```tsx
const journey = useContext(JourneyContext)
const journeyActive = !!journey?.entryPoint
```

- [ ] **Step 2: Apply disabled state to the trigger**

Whatever Radix or button primitive the menu uses, pass `disabled={journeyActive}` and add a title attribute: `title={journeyActive ? 'Controlled by Journey mode' : undefined}`. If the menu uses a `DropdownMenu.Trigger`, the `disabled` prop goes on the button inside it.

- [ ] **Step 3: Write Vitest for the disabled state**

```tsx
it('renders the ShowMode trigger disabled when a journey is active', () => {
  render(
    <AllProvidersWrapper journeyEntryPoint={{ identifier: 'X', verb: 'GET', path: '/x', action: 'show' }}>
      <ShowModeMenu />
    </AllProvidersWrapper>
  )
  expect(screen.getByRole('button', { name: /show mode/i })).toBeDisabled()
})
```

Adjust the accessible name to match the existing aria-label.

- [ ] **Step 4: Run test**

```
pnpm --filter @liam-hq/erd-core test -- --run ShowModeMenu
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/ShowModeMenu/ShowModeMenu.tsx <test file>
git commit -m "Disable ShowModeMenu trigger while journey is active"
```

---

### Task 9: Navigation edges toolbar toggle

A single button beside the Fit and TidyUp actions. When on, include navigation edges in `displayEdges`; when off, omit them.

**Files:**
- Create: `packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/NavigationEdgesToggle/NavigationEdgesToggle.tsx`
- Create: `packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/NavigationEdgesToggle/index.ts`
- Modify: `packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/DesktopToolbar.tsx`
- Modify: `packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx` — extend `displayEdges` filter
- Test: `packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/NavigationEdgesToggle/NavigationEdgesToggle.test.tsx`

- [ ] **Step 1: Create the toggle component**

```tsx
// NavigationEdgesToggle.tsx
import { Toggle } from '@radix-ui/react-toolbar'
import { useUserEditingOrThrow } from '@/stores'
import { ToolbarIconButton } from '../ToolbarIconButton'

export const NavigationEdgesToggle = () => {
  const { navigationEdgesVisible, setNavigationEdgesVisible } = useUserEditingOrThrow()
  return (
    <ToolbarIconButton
      tooltipContent={navigationEdgesVisible ? 'Hide navigation edges' : 'Show navigation edges'}
      label="Toggle navigation edges"
      onClick={() => setNavigationEdgesVisible(!navigationEdgesVisible)}
      aria-pressed={navigationEdgesVisible}
    >
      {/* use an arrow or route icon from the existing icon set; check ToolbarIconButton siblings for examples */}
      <span aria-hidden>→</span>
    </ToolbarIconButton>
  )
}
```

Match the real `ToolbarIconButton` API by reading `ToolbarIconButton.tsx` first; if it takes different props (e.g., `icon` instead of children), adjust.

Create `index.ts`:
```ts
export * from './NavigationEdgesToggle'
```

- [ ] **Step 2: Mount in DesktopToolbar**

Edit `DesktopToolbar.tsx` — add import and render inside the `buttons` div after `TidyUpButton`:

```tsx
import { NavigationEdgesToggle } from './NavigationEdgesToggle'
// ...
<FitviewButton />
<TidyUpButton />
<NavigationEdgesToggle />
{customActions}
```

- [ ] **Step 3: Extend ErdContent edge filtering**

Find where `displayEdges` is computed in `ErdContent.tsx`. Add navigation inclusion:

```tsx
const { navigationEdgesVisible } = useUserEditingOrThrow()

const displayEdges = useMemo(() => {
  const NAV_VIAS = new Set(['link_to', 'redirect_to', 'form_action'])
  return edges
    .filter(e => {
      if (isJourneyActive) return journey.result?.edges?.some(je => je.id === e.id) ?? false
      if (navigationEdgesVisible) return true // include everything while toggle is on
      return !NAV_VIAS.has(e.data?.via as string) // default: hide nav edges
    })
    .map(/* existing mapping */)
}, [edges, navigationEdgesVisible, isJourneyActive, journey?.result])
```

Confirm the default Explore behaviour (`!NAV_VIAS.has(...)`) matches current pre-journey behaviour. If today's Explore mode already renders nav edges, simplify: when `navigationEdgesVisible` is off, hide nav edges; when on, show everything. Whichever is the current default should be the default with toggle off.

- [ ] **Step 4: Write Vitest**

```tsx
it('pressing the toggle flips navigationEdgesVisible', async () => {
  const user = userEvent.setup()
  render(<AllProvidersWrapper><NavigationEdgesToggle /></AllProvidersWrapper>)
  const btn = screen.getByRole('button', { name: /toggle navigation edges/i })
  expect(btn).toHaveAttribute('aria-pressed', 'false')
  await user.click(btn)
  expect(btn).toHaveAttribute('aria-pressed', 'true')
})
```

- [ ] **Step 5: Run test**

```
pnpm --filter @liam-hq/erd-core test -- --run NavigationEdgesToggle
```

Expected: PASS.

- [ ] **Step 6: Manually verify in the testbed**

Load the ERD in Explore mode. Click the new toolbar button. Confirm nav edges appear/disappear without changing the Layers (`ShowMode`) state.

- [ ] **Step 7: Commit**

```bash
git add packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/NavigationEdgesToggle/ packages/erd-core/src/features/erd/components/ERDRenderer/Toolbar/DesktopToolbar.tsx packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx
git commit -m "Add Navigation edges toolbar toggle in Explore mode"
```

---

### Task 10: Filter canvas to walked subgraph only

Replace the v1 "dim non-journey nodes" approach with "hide non-journey nodes entirely" while journey is active.

**Files:**
- Modify: `packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx`
- Modify: `packages/erd-core/src/features/journey/journey.module.css` — remove `.erd-node--outside-journey` rule

- [ ] **Step 1: Write failing test**

In `ErdContent.test.tsx` (create if absent):

```tsx
it('renders only walked nodes while journey is active', () => {
  const journeyEntry = { identifier: 'A', verb: 'GET', path: '/a', action: 'show' }
  render(<AllProvidersWrapper journeyEntryPoint={journeyEntry} schemaWithNodes={threeNodesWhereOnlyAIsWalked}>
    <ErdContent />
  </AllProvidersWrapper>)
  expect(screen.queryByTestId('node-A')).toBeInTheDocument()
  expect(screen.queryByTestId('node-B')).not.toBeInTheDocument()
})
```

Build the fixture so the walk result contains only node A.

- [ ] **Step 2: Run test to verify it fails**

```
pnpm --filter @liam-hq/erd-core test -- --run ErdContent
```

Expected: FAIL — all nodes are still rendered.

- [ ] **Step 3: Filter displayNodes by walk membership**

Replace the v1 "add `erd-node--outside-journey` class" with:

```tsx
const displayNodes = useMemo(() => {
  if (isJourneyActive && journey?.result) {
    return nodes.filter(n => journey.result!.nodes.has(n.id))
      .map(n => ({
        ...n,
        className: journey.entryPoint?.identifier === n.id ? 'erd-node--journey-entry' : undefined,
      }))
  }
  // existing Explore-mode mapping
  return nodes
}, [nodes, isJourneyActive, journey?.result, journey?.entryPoint])
```

- [ ] **Step 4: Delete the dim style**

In `journey.module.css`, remove the `:global(.erd-node--outside-journey)` block (including its opacity rule). Leave the `.erd-node--journey-entry` rule intact.

- [ ] **Step 5: Run test to verify it passes**

```
pnpm --filter @liam-hq/erd-core test -- --run ErdContent
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/erd-core/src/features/erd/components/ERDContent/ErdContent.tsx packages/erd-core/src/features/journey/journey.module.css <test file>
git commit -m "Journey mode: render walked subgraph only, drop dim style"
```

---

### Task 11: Strip edge-type checkboxes from JourneyBanner

Journey v2 always shows all navigation edges; remove the per-type checkboxes.

**Files:**
- Modify: `packages/erd-core/src/features/journey/JourneyBanner.tsx`
- Modify: `packages/erd-core/src/features/journey/JourneyContext.tsx` — remove the `enabledEdgeTypes` state if unused elsewhere (only remove if Grep confirms no other consumers)

- [ ] **Step 1: Grep for enabledEdgeTypes consumers**

```
grep -rn "enabledEdgeTypes" packages/erd-core/src/
```

List every file. If the only consumer is `JourneyBanner.tsx` + `JourneyContext.tsx` + the walker test, delete the state. Otherwise keep it but hide the UI.

- [ ] **Step 2: Remove the checkbox JSX from JourneyBanner**

In `JourneyBanner.tsx`, delete the block that renders the three checkboxes (`link_to`, `redirect_to`, `form_action`). Keep title, verb/path/identifier#action, reach count, depth dropdown, and Exit button.

- [ ] **Step 3: Remove enabledEdgeTypes state from the provider (if Step 1 allowed)**

Delete the `useState`/setter for `enabledEdgeTypes` in `JourneyContext.tsx`. Update the `walker` call to default to all nav edge types unconditionally.

- [ ] **Step 4: Update or remove the banner snapshot test**

If `useJourneyMode.test.tsx` or a banner test references `enabledEdgeTypes`, delete those assertions. Run:

```
pnpm --filter @liam-hq/erd-core test -- --run journey
```

Expected: PASS across all journey tests.

- [ ] **Step 5: Commit**

```bash
git add packages/erd-core/src/features/journey/JourneyBanner.tsx packages/erd-core/src/features/journey/JourneyContext.tsx <test files>
git commit -m "Drop edge-type checkboxes from JourneyBanner"
```

---

### Task 12: Manual end-to-end verification in the smoke testbed

**Files:** none modified. This is a verification task.

- [ ] **Step 1: Rebuild CLI and reload ERD**

```
pnpm --filter @liam-hq/erd-core build
pnpm --filter @liam-hq/cli build
```

Then restart the testbed per `docs/TESTBED.md`.

- [ ] **Step 2: Verify Bug 1 fix**

Open ⌘K, type a known entry-point name. Confirm the Entry Points group renders above Controllers.

- [ ] **Step 3: Verify mode split**

- Enter Explore mode. Focus a table (click a node) — confirm focus works.
- Open ⌘K, pick an entry point. Confirm: focus clears, Layers menu is disabled, canvas shows only walked nodes, auto-frames on the subgraph.
- Click Exit on the banner. Confirm: focus returns, Layers re-enables, canvas restores previous viewport.

- [ ] **Step 4: Verify Navigation edges toggle**

In Explore mode, toggle the new toolbar button. Confirm nav edges appear/disappear. Change ShowMode between variants while the toggle is on — confirm nav edges persist through show-mode changes.

- [ ] **Step 5: Document results**

Append a short `Task 12 verification:` block to the end of this plan file listing the four checks with PASS/FAIL. Commit.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/plans/2026-04-22-user-journey-v2.md
git commit -m "Document journey v2 smoke-test verification"
```

---

## Self-review

**Spec coverage:**
- ✅ Bug 1 (entryPoints data flow) → Tasks 1–2
- ✅ Mode snapshot/restore (showMode, hiddenNodeIds, activeTableName, viewport) → Tasks 4, 5, 7
- ✅ Auto-exit Focus → Task 6
- ✅ Disable Layers while journey active → Task 8
- ✅ Filter canvas to walked subgraph, drop dim style → Task 10
- ✅ Auto-frame subgraph + restore viewport → Task 7
- ✅ Navigation edges toolbar toggle → Task 3 (state) + Task 9 (UI)
- ✅ Remove edge-type checkboxes → Task 11
- ✅ End-to-end verification → Task 12

**Placeholder scan:** No TBD / TODO / "similar to Task N" references. Each task includes concrete code. Task 1 is a diagnostic task with explicit steps rather than a fix, which is intentional — the diagnostic is the work.

**Type consistency:**
- `ExploreSnapshot` defined in Task 4, referenced consistently in Tasks 5 and 7.
- `navigationEdgesVisible` / `setNavigationEdgesVisible` introduced in Task 3, consumed in Tasks 9 + 10.
- `snapshot.viewport` set by `setSnapshotViewport` (Task 7) and read by `exitJourney`'s restore path.

Plan complete and saved to `docs/superpowers/plans/2026-04-22-user-journey-v2.md`.
