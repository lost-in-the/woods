import { Waypoints } from '@liam-hq/ui'
import type { FC } from 'react'
import { useUserEditingOrThrow } from '@/stores'
import { ToolbarIconButton } from '../ToolbarIconButton'

export const NavigationEdgesToggle: FC = () => {
  const { navigationEdgesVisible, setNavigationEdgesVisible } =
    useUserEditingOrThrow()

  return (
    <ToolbarIconButton
      tooltipContent={
        navigationEdgesVisible
          ? 'Hide navigation edges'
          : 'Show navigation edges'
      }
      label="Toggle navigation edges"
      icon={<Waypoints />}
      onClick={() => setNavigationEdgesVisible(!navigationEdgesVisible)}
      pressed={navigationEdgesVisible}
    />
  )
}
