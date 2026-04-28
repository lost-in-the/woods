'use client'

import clsx from 'clsx'
import { GripVertical } from 'lucide-react'
import type { ComponentProps, Ref } from 'react'
import * as ResizablePrimitive from 'react-resizable-panels'
import styles from './Resizable.module.css'

const ResizablePanelGroup = ({
  className,
  ...props
}: ComponentProps<typeof ResizablePrimitive.PanelGroup>) => (
  <ResizablePrimitive.PanelGroup
    className={clsx(styles.panelGroup, className)}
    {...props}
  />
)

const ResizablePanel = ({
  className,
  isResizing,
  ref,
  ...props
}: ComponentProps<typeof ResizablePrimitive.Panel> & {
  isResizing: boolean
  ref?: Ref<ResizablePrimitive.ImperativePanelHandle>
}) => (
  <ResizablePrimitive.Panel
    ref={ref}
    className={clsx(!isResizing && styles.panelAnimating, className)}
    {...props}
  />
)
ResizablePanel.displayName = 'ResizablePanel'

export type ImperativePanelHandle = ResizablePrimitive.ImperativePanelHandle

const ResizableHandle = ({
  withHandle,
  className,
  ...props
}: ComponentProps<typeof ResizablePrimitive.PanelResizeHandle> & {
  withHandle?: boolean
}) => (
  <ResizablePrimitive.PanelResizeHandle
    className={clsx(styles.handle, className)}
    {...props}
  >
    {withHandle && (
      <div className={styles.handleIcon}>
        <GripVertical className={styles.gripIcon} />
      </div>
    )}
  </ResizablePrimitive.PanelResizeHandle>
)

export { ResizablePanelGroup, ResizablePanel, ResizableHandle }
