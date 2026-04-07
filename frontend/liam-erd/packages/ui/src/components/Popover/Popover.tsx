'use client'

import * as PopoverPrimitive from '@radix-ui/react-popover'
import { clsx } from 'clsx'
import type { ComponentPropsWithoutRef, ElementRef, Ref } from 'react'
import styles from './Popover.module.css'

export const PopoverRoot = PopoverPrimitive.Root

export const PopoverTrigger = PopoverPrimitive.Trigger

export const PopoverAnchor = PopoverPrimitive.Anchor

export const PopoverPortal = PopoverPrimitive.Portal

export const PopoverContent = ({
  className,
  children,
  ref,
  ...props
}: ComponentPropsWithoutRef<typeof PopoverPrimitive.Content> & {
  ref?: Ref<ElementRef<typeof PopoverPrimitive.Content>>
}) => (
  <PopoverPrimitive.Content
    ref={ref}
    {...props}
    className={clsx(className, styles.content)}
  >
    {children}
  </PopoverPrimitive.Content>
)
PopoverContent.displayName = PopoverPrimitive.Content.displayName

export const PopoverClose = PopoverPrimitive.Close
