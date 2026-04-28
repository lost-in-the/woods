import { describe, expect, it } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { NuqsTestingAdapter } from 'nuqs/adapters/testing'
import { UserEditingProvider } from '@/stores/userEditing/Provider'
import { useUserEditingOrThrow } from '@/stores/userEditing/hooks'
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

function allProvidersWrapper(ui: ReactNode) {
  return (
    <NuqsTestingAdapter>
      <UserEditingProvider>
        <JourneyProvider schema={schema}>{ui}</JourneyProvider>
      </UserEditingProvider>
    </NuqsTestingAdapter>
  )
}

describe('useJourneyMode', () => {
  it('is inactive by default', () => {
    const { result } = renderHook(() => useJourneyMode(), {
      wrapper: ({ children }) => allProvidersWrapper(children),
    })
    expect(result.current.entryPoint).toBeNull()
    expect(result.current.result).toBeNull()
  })

  it('enters journey mode and computes the walk', () => {
    const { result } = renderHook(() => useJourneyMode(), {
      wrapper: ({ children }) => allProvidersWrapper(children),
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
      wrapper: ({ children }) => allProvidersWrapper(children),
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
      wrapper: ({ children }) => allProvidersWrapper(children),
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

  it('snapshots showMode and activeTableName on enterJourney', () => {
    const { result } = renderHook(
      () => ({ journey: useJourneyMode(), user: useUserEditingOrThrow() }),
      { wrapper: ({ children }) => allProvidersWrapper(children) },
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
      viewport: null,
    })
  })

  it('restores showMode and activeTableName on exitJourney', () => {
    const { result } = renderHook(
      () => ({ journey: useJourneyMode(), user: useUserEditingOrThrow() }),
      { wrapper: ({ children }) => allProvidersWrapper(children) },
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

  it('clears activeTableName on enterJourney (auto-exit Focus)', async () => {
    const { result } = renderHook(
      () => ({ journey: useJourneyMode(), user: useUserEditingOrThrow() }),
      { wrapper: ({ children }) => allProvidersWrapper(children) },
    )
    await act(async () => result.current.user.setActiveTableName('users'))
    act(() =>
      result.current.journey.enterJourney({ identifier: 'X', verb: 'GET', path: '/x', action: 'show' }),
    )
    expect(result.current.user.activeTableName).toBeFalsy()
  })

  it('setSnapshotViewport merges viewport into existing snapshot without clobbering other fields', async () => {
    const { result } = renderHook(
      () => ({ journey: useJourneyMode(), user: useUserEditingOrThrow() }),
      { wrapper: ({ children }) => allProvidersWrapper(children) },
    )
    await act(async () => {
      result.current.user.setShowMode('TABLE_NAME')
      await result.current.user.setActiveTableName('orders')
    })
    act(() => {
      result.current.journey.enterJourney({
        identifier: 'CheckoutController',
        verb: 'GET',
        path: '/checkout',
        action: 'new',
      })
    })
    // snapshot exists but viewport is null (filled by the viewport effect)
    expect(result.current.journey.snapshot?.viewport).toBeNull()

    const vp = { x: 100, y: 200, zoom: 1.5 }
    act(() => {
      result.current.journey.setSnapshotViewport(vp)
    })

    expect(result.current.journey.snapshot?.viewport).toEqual(vp)
    // other snapshot fields must be preserved
    expect(result.current.journey.snapshot?.showMode).toBe('TABLE_NAME')
    expect(result.current.journey.snapshot?.activeTableName).toBe('orders')
  })

  it('setSnapshotViewport is a no-op when snapshot is null', async () => {
    const { result } = renderHook(() => useJourneyMode(), {
      wrapper: ({ children }) => allProvidersWrapper(children),
    })
    await act(async () => {})
    // snapshot is null before enterJourney
    act(() => {
      result.current.setSnapshotViewport({ x: 0, y: 0, zoom: 1 })
    })
    expect(result.current.snapshot).toBeNull()
  })
})
