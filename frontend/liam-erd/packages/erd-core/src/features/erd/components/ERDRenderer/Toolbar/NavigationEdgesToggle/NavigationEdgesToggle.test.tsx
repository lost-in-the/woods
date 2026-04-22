import * as ToolbarPrimitive from '@radix-ui/react-toolbar'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { NuqsTestingAdapter } from 'nuqs/adapters/testing'
import { describe, expect, it } from 'vitest'
import { UserEditingProvider } from '@/stores/userEditing/Provider'
import { NavigationEdgesToggle } from './NavigationEdgesToggle'

function Providers({ children }: { children: React.ReactNode }) {
  return (
    <NuqsTestingAdapter>
      <UserEditingProvider>
        <ToolbarPrimitive.Root>{children}</ToolbarPrimitive.Root>
      </UserEditingProvider>
    </NuqsTestingAdapter>
  )
}

describe('NavigationEdgesToggle', () => {
  it('toggles aria-pressed when clicked', async () => {
    const user = userEvent.setup()
    render(
      <Providers>
        <NavigationEdgesToggle />
      </Providers>,
    )
    const btn = screen.getByRole('button', { name: /toggle navigation edges/i })
    expect(btn).toHaveAttribute('aria-pressed', 'false')
    await user.click(btn)
    expect(btn).toHaveAttribute('aria-pressed', 'true')
  })
})
