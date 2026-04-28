'use client'

import {
  Content,
  Portal,
  Provider,
  Root,
  Trigger,
} from '@radix-ui/react-tooltip'
import type { ComponentProps, FC, Ref } from 'react'
import styles from './Tooltip.module.css'

export const TooltipContent = ({
  ref,
  ...props
}: ComponentProps<typeof Content> & {
  ref?: Ref<HTMLDivElement>
}) => {
  return <Content {...props} ref={ref} className={styles.content} />
}

TooltipContent.displayName = 'TooltipContent'

export const TooltipProvider: FC<ComponentProps<typeof Provider>> = ({
  children,
  ...props
}) => {
  return (
    <Provider delayDuration={100} {...props}>
      {children}
    </Provider>
  )
}
export const TooltipPortal = Portal
export const TooltipRoot = Root
export const TooltipTrigger = Trigger
