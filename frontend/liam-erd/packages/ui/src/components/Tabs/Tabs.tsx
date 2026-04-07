'use client'

import { Content, List, Root, Trigger } from '@radix-ui/react-tabs'
import type { ComponentProps, Ref } from 'react'

export const TabsRoot = ({
  ref,
  ...props
}: ComponentProps<typeof Root> & {
  ref?: Ref<HTMLDivElement>
}) => {
  return <Root {...props} ref={ref} />
}
TabsRoot.displayName = 'TabsRoot'

export const TabsList = ({
  ref,
  ...props
}: ComponentProps<typeof List> & {
  ref?: Ref<HTMLDivElement>
}) => {
  return <List {...props} ref={ref} />
}
TabsList.displayName = 'TabsList'

export const TabsTrigger = ({
  ref,
  ...props
}: ComponentProps<typeof Trigger> & {
  ref?: Ref<HTMLButtonElement>
}) => {
  return <Trigger {...props} ref={ref} />
}
TabsTrigger.displayName = 'TabsTrigger'

export const TabsContent = ({
  ref,
  ...props
}: ComponentProps<typeof Content> & {
  ref?: Ref<HTMLDivElement>
}) => {
  return <Content {...props} ref={ref} />
}
TabsContent.displayName = 'TabsContent'
