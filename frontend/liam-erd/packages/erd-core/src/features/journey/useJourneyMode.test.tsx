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
