import { act, renderHook } from '@testing-library/react'
import { NuqsTestingAdapter } from 'nuqs/adapters/testing'
import { describe, expect, it } from 'vitest'
import { useUserEditingOrThrow } from './hooks'
import { UserEditingProvider } from './Provider'

describe('UserEditingContext navigationEdgesVisible', () => {
  it('defaults to false', () => {
    const { result } = renderHook(() => useUserEditingOrThrow(), {
      wrapper: ({ children }) => (
        <NuqsTestingAdapter>
          <UserEditingProvider>{children}</UserEditingProvider>
        </NuqsTestingAdapter>
      ),
    })
    expect(result.current.navigationEdgesVisible).toBe(false)
  })

  it('toggles via setNavigationEdgesVisible', () => {
    const { result } = renderHook(() => useUserEditingOrThrow(), {
      wrapper: ({ children }) => (
        <NuqsTestingAdapter>
          <UserEditingProvider>{children}</UserEditingProvider>
        </NuqsTestingAdapter>
      ),
    })
    act(() => result.current.setNavigationEdgesVisible(true))
    expect(result.current.navigationEdgesVisible).toBe(true)
  })
})
