import '@xyflow/react/dist/style.css'
import {
  type ImperativePanelHandle,
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
  SidebarProvider,
  SidebarTrigger,
  ToastProvider,
} from '@liam-hq/ui'
import { ReactFlowProvider } from '@xyflow/react'
import {
  type ComponentProps,
  createRef,
  type FC,
  type ReactNode,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from 'react'
import { AppBar } from './AppBar'
import styles from './ERDRenderer.module.css'
import '@/styles/globals.css'
import { toggleLogEvent } from '@/features/gtm/utils'
import { useIsTouchDevice } from '@/hooks'
import { useVersionOrThrow } from '@/providers'
import { useSchemaOrThrow, useUserEditingOrThrow } from '@/stores'
import {
  convertSchemaToNodes,
  createHash,
  setCookie,
  setCookieJson,
} from '../../utils'
import { ERDContent } from '../ERDContent'
import {
  LayerToggleDropdown,
  filterByFocus,
  filterEdgesByLayers,
  useLayerState,
} from '../LayerToggle'
import { CardinalityMarkers } from './CardinalityMarkers'
import { CommandPalette, CommandPaletteProvider } from './CommandPalette'
import { ErrorDisplay } from './ErrorDisplay'
import { FocusBanner } from './FocusBanner'
import { LeftPane } from './LeftPane'
import { RelationshipEdgeParticleMarker } from './RelationshipEdgeParticleMarker'
import { TableDetailDrawer, TableDetailDrawerRoot } from './TableDetailDrawer'
import { Toolbar } from './Toolbar'

type Props = {
  defaultSidebarOpen?: boolean | undefined
  errorObjects?: ComponentProps<typeof ErrorDisplay>['errors']
  defaultPanelSizes?: number[]
  withAppBar?: boolean
  customToolbarActions?: ReactNode
}

const SIDEBAR_COOKIE_NAME = 'sidebar:state'
const PANEL_LAYOUT_COOKIE_NAME = 'panels:layout'
const COOKIE_MAX_AGE = 60 * 60 * 24 * 7

export const ERDRenderer: FC<Props> = ({
  defaultSidebarOpen = false,
  errorObjects = [],
  defaultPanelSizes = [20, 80],
  withAppBar = false,
  customToolbarActions,
}) => {
  const [open, setOpen] = useState(defaultSidebarOpen)
  const [isResizing, setIsResizing] = useState(false)

  const { showMode, showDiff } = useUserEditingOrThrow()

  const { current, merged } = useSchemaOrThrow()

  const schema = useMemo(() => {
    return showDiff && merged ? merged : current
  }, [showDiff, merged, current])

  const schemaKey = useMemo(() => {
    const str = JSON.stringify(schema)
    return createHash(str)
  }, [schema])

  const {
    nodeLayers,
    edgeCategories,
    toggleNodeLayer,
    toggleEdgeCategory,
    focusedNodes,
    setFocusedNodes,
    toggleFocusedNode,
  } = useLayerState()

  const { nodes, edges } = convertSchemaToNodes({
    schema,
    showMode,
    nodeLayers,
  })

  const visibleNodeIds = useMemo(
    () => new Set(nodes.map((n) => n.id)),
    [nodes],
  )
  const filteredEdges = useMemo(
    () => filterEdgesByLayers(edges, edgeCategories, visibleNodeIds),
    [edges, edgeCategories, visibleNodeIds],
  )

  const { nodes: visibleNodes, edges: visibleEdges } = useMemo(
    () => filterByFocus(nodes, filteredEdges, focusedNodes),
    [nodes, filteredEdges, focusedNodes],
  )

  // Encode active layers into a key fragment so ERDContent re-mounts (and
  // re-layouts via ELK) when the user toggles node layers on or off.
  const layerKey = useMemo(
    () =>
      Object.entries(nodeLayers)
        .filter(([, v]) => v)
        .map(([k]) => k)
        .sort()
        .join(','),
    [nodeLayers],
  )

  const focusKey = useMemo(
    () => Array.from(focusedNodes).sort().join(','),
    [focusedNodes],
  )

  const handleFocusNode = useCallback(
    (nodeId: string | null) => {
      setFocusedNodes(nodeId ? new Set([nodeId]) : new Set())
    },
    [setFocusedNodes],
  )

  useEffect(() => {
    const down = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && focusedNodes.size > 0) {
        setFocusedNodes(new Set())
      }
    }
    document.addEventListener('keydown', down)
    return () => document.removeEventListener('keydown', down)
  }, [focusedNodes, setFocusedNodes])

  useEffect(() => {
    const handleFocus = (e: Event) => {
      const detail = (e as CustomEvent<{ nodeId: string }>).detail
      setFocusedNodes(new Set([detail.nodeId]))
    }
    const handleToggle = (e: Event) => {
      const detail = (e as CustomEvent<{ nodeId: string }>).detail
      toggleFocusedNode(detail.nodeId)
    }
    window.addEventListener('erd:focus-node', handleFocus)
    window.addEventListener('erd:toggle-focus-node', handleToggle)
    return () => {
      window.removeEventListener('erd:focus-node', handleFocus)
      window.removeEventListener('erd:toggle-focus-node', handleToggle)
    }
  }, [setFocusedNodes, toggleFocusedNode])

  const leftPanelRef = createRef<ImperativePanelHandle>()

  const { version } = useVersionOrThrow()
  const handleChangeOpen = useCallback(
    (nextPanelState: boolean) => {
      setOpen(nextPanelState)
      toggleLogEvent({
        element: 'leftPane',
        isShow: nextPanelState,
        platform: version.displayedOn,
        gitHash: version.gitHash,
        ver: version.version,
        appEnv: version.envName,
      })

      nextPanelState === false
        ? leftPanelRef.current?.collapse()
        : leftPanelRef.current?.expand()

      setCookie(SIDEBAR_COOKIE_NAME, nextPanelState.toString(), {
        path: '/',
        maxAge: COOKIE_MAX_AGE,
      })
    },
    [version, leftPanelRef],
  )

  const setWidth = useCallback((sizes: number[]) => {
    setCookieJson(PANEL_LAYOUT_COOKIE_NAME, sizes, {
      path: '/',
      maxAge: COOKIE_MAX_AGE,
    })
  }, [])

  const isMobile = useIsTouchDevice()

  return (
    <SidebarProvider
      className={styles.wrapper}
      open={open}
      onOpenChange={handleChangeOpen}
    >
      <CardinalityMarkers />
      <RelationshipEdgeParticleMarker />
      <ToastProvider>
        <CommandPaletteProvider>
          {withAppBar && <AppBar />}
          <ReactFlowProvider>
            <ResizablePanelGroup
              direction="horizontal"
              className={styles.mainWrapper}
              onLayout={setWidth}
            >
              <ResizablePanel
                collapsible
                defaultSize={open ? defaultPanelSizes[0] : 0}
                minSize={isMobile ? 40 : 15}
                maxSize={isMobile ? 80 : 30}
                ref={leftPanelRef}
                isResizing={isResizing}
                onResize={(size: number) => {
                  if (open && size < 15) {
                    handleChangeOpen(false)
                  }
                }}
              >
                <LeftPane
                  onFocusNode={handleFocusNode}
                  nodeLayers={nodeLayers}
                />
              </ResizablePanel>
              <ResizableHandle onDragging={(e) => setIsResizing(e)} />
              <ResizablePanel
                collapsible
                defaultSize={defaultPanelSizes[1]}
                isResizing={isResizing}
              >
                <main className={styles.main}>
                  <div className={styles.triggerWrapper}>
                    <SidebarTrigger />
                  </div>
                  <TableDetailDrawerRoot>
                    {errorObjects.length > 0 && (
                      <ErrorDisplay errors={errorObjects} />
                    )}
                    {errorObjects.length > 0 || (
                      <>
                        {focusedNodes.size > 0 && (
                          <FocusBanner
                            focusedNodes={focusedNodes}
                            onRemoveNode={(nodeId) => {
                              const next = new Set(focusedNodes)
                              next.delete(nodeId)
                              setFocusedNodes(next)
                            }}
                            onExitFocus={() => setFocusedNodes(new Set())}
                          />
                        )}
                        <ERDContent
                          key={`${schemaKey}-${showMode}-${layerKey}-${focusKey}`}
                          nodes={visibleNodes}
                          edges={visibleEdges}
                          displayArea="main"
                        />
                        <TableDetailDrawer />
                      </>
                    )}
                  </TableDetailDrawerRoot>
                  {errorObjects.length === 0 && (
                    <div className={styles.toolbarWrapper}>
                      <Toolbar
                        customActions={
                          <>
                            <LayerToggleDropdown
                              nodeLayers={nodeLayers}
                              edgeCategories={edgeCategories}
                              onToggleNodeLayer={toggleNodeLayer}
                              onToggleEdgeCategory={toggleEdgeCategory}
                            />
                            {customToolbarActions}
                          </>
                        }
                      />
                    </div>
                  )}
                </main>
              </ResizablePanel>
            </ResizablePanelGroup>
            <CommandPalette />
          </ReactFlowProvider>
        </CommandPaletteProvider>
      </ToastProvider>
    </SidebarProvider>
  )
}
