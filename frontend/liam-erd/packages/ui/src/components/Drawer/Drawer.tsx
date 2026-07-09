'use client'

import { clsx } from 'clsx'
import type { ComponentPropsWithoutRef, ElementRef, Ref } from 'react'
import { Drawer } from 'vaul'
import styles from './Drawer.module.css'

export const DrawerRoot = Drawer.Root

export const DrawerTrigger = Drawer.Trigger

export const DrawerPortal = Drawer.Portal

export const DrawerContent = ({
  className,
  children,
  ref,
  ...props
}: ComponentPropsWithoutRef<typeof Drawer.Content> & {
  ref?: Ref<ElementRef<typeof Drawer.Content>>
}) => (
  <Drawer.Content
    ref={ref}
    {...props}
    className={clsx(className, styles.content)}
  >
    {children}
  </Drawer.Content>
)
DrawerContent.displayName = Drawer.Content.displayName

export const DrawerTitle = Drawer.Title

export const DrawerDescription = Drawer.Description

export const DrawerClose = Drawer.Close
