import {
  Background,
  BackgroundVariant,
  type Edge,
  type Node,
  type NodeMouseHandler,
  type OnNodeDrag,
  ReactFlow,
  useEdgesState,
  useNodesState,
  useReactFlow,
} from '@xyflow/react'
import { type FC, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { useTableSelection } from '@/features/erd/hooks'
import type { DisplayArea, WoodsNodeType } from '@/features/erd/types'
import { selectTableLogEvent } from '@/features/gtm/utils'
import { repositionTableLogEvent } from '@/features/gtm/utils/repositionTableLogEvent'
import { MAX_ZOOM, MIN_ZOOM } from '@/features/reactflow/constants'
import { useVersionOrThrow } from '@/providers'
import { useUserEditingOrThrow } from '@/stores'
import { JourneyContext } from '@/features/journey'
import { highlightNodesAndEdges, isTableNode } from '../../utils'
import {
  NonRelatedTableGroupNode,
  RelationshipEdge,
  Spinner,
  TableNode,
  WoodsNode,
} from './components'
import styles from './ERDContent.module.css'
import { ErdContentProvider, useErdContentContext } from './ErdContentContext'
import { useInitialAutoLayout, useQueryParamsChanged } from './hooks'

const NAV_VIAS: ReadonlySet<string> = new Set(['link_to', 'redirect_to', 'form_action'])

const nodeTypes = {
  table: TableNode,
  nonRelatedTableGroup: NonRelatedTableGroupNode,
  woodsNode: WoodsNode,
}

const edgeTypes = {
  relationship: RelationshipEdge,
}

type Props = {
  nodes: Node[]
  edges: Edge[]
  displayArea: DisplayArea
}

export const ERDContentInner: FC<Props> = ({
  nodes: _nodes,
  edges: _edges,
  displayArea,
}) => {
  const [nodes, setNodes, onNodesChange] = useNodesState<Node>(
    displayArea === 'relatedTables'
      ? _nodes.map((node) =>
          isTableNode(node)
            ? { ...node, data: { ...node.data, showMode: 'TABLE_NAME' } }
            : node,
        )
      : _nodes,
  )

  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>(_edges)

  const journeyCtx = useContext(JourneyContext)
  const journeyEntryPoint = journeyCtx?.entryPoint ?? null
  const journeySnapshot = journeyCtx?.snapshot ?? null
  const journeyResult = journeyCtx?.result ?? null
  const setSnapshotViewport = journeyCtx?.setSnapshotViewport

  const journeyNodeIds = useMemo(
    () => journeyResult?.nodes ?? null,
    [journeyResult],
  )
  const journeyEdges = useMemo(
    () => journeyResult?.edges ?? null,
    [journeyResult],
  )

  const { activeTableName, navigationEdgesVisible } = useUserEditingOrThrow()
  const reactFlow = useReactFlow()

  useEffect(() => {
    if (journeyEntryPoint && journeySnapshot && !journeySnapshot.viewport) {
      // Just entered journey: capture current viewport, then fit to subgraph
      setSnapshotViewport?.(reactFlow.getViewport())
      const walkedIds = Array.from(journeyResult?.nodes.keys() ?? [])
      if (walkedIds.length > 0) {
        reactFlow.fitView({
          nodes: walkedIds.map((id) => ({ id })),
          duration: 400,
          padding: 0.2,
        })
      }
    }

    if (!journeyEntryPoint && journeySnapshot?.viewport) {
      // Exiting journey: restore saved viewport
      reactFlow.setViewport(journeySnapshot.viewport, { duration: 400 })
    }
  }, [
    journeyEntryPoint,
    journeySnapshot,
    journeyResult,
    setSnapshotViewport,
    reactFlow,
  ])

  const displayNodes = useMemo(() => {
    if (!journeyNodeIds) return nodes
    // Journey mode: render only walked nodes, mark the entry point.
    return nodes
      .filter((node) => journeyNodeIds.has(node.id))
      .map((node) => {
        if (node.id !== journeyEntryPoint?.identifier) return node
        return {
          ...node,
          className: [node.className, 'erd-node--journey-entry']
            .filter(Boolean)
            .join(' '),
        }
      })
  }, [nodes, journeyNodeIds, journeyEntryPoint])

  const displayEdges = useMemo(
    () =>
      edges
        .filter((edge) => {
          // In journey mode, the journey walk result controls which edges are shown —
          // never filter nav edges away from a journey walk.
          if (journeyEdges !== null) return true
          // Outside journey: hide nav edges when the toggle is off (default).
          if (!navigationEdgesVisible) {
            const via = edge.data?.['via']
            if (typeof via === 'string' && NAV_VIAS.has(via)) return false
          }
          return true
        })
        .map((edge) => {
          const viaClass =
            typeof edge.data?.['via'] === 'string'
              ? `erd-edge--${edge.data['via']}`
              : ''
          const backEdgeClass =
            journeyEdges?.find(
              (e) =>
                e.from === edge.source &&
                e.to === edge.target &&
                e.isBackEdge,
            )
              ? 'erd-edge--back-edge'
              : ''
          if (!viaClass && !backEdgeClass) return edge
          return {
            ...edge,
            className: [edge.className, viaClass, backEdgeClass]
              .filter(Boolean)
              .join(' '),
          }
        }),
    [edges, journeyEdges, navigationEdgesVisible],
  )

  const {
    state: { loading },
  } = useErdContentContext()

  const { selectTable, deselectTable } = useTableSelection()

  useInitialAutoLayout({
    nodes,
    displayArea,
  })
  useQueryParamsChanged({
    displayArea,
  })

  const { version } = useVersionOrThrow()
  const handleNodeClick = useCallback(
    (tableId: string) => {
      selectTable({
        tableId,
        displayArea,
      })

      selectTableLogEvent({
        ref: 'mainArea',
        tableId,
        platform: version.displayedOn,
        gitHash: version.gitHash,
        ver: version.version,
        appEnv: version.envName,
      })
    },
    [version, displayArea, selectTable],
  )

  const handlePaneClick = useCallback(() => {
    deselectTable()
  }, [deselectTable])

  const handleMouseEnterNode: NodeMouseHandler<Node> = useCallback(
    (_, { id }) => {
      const { nodes: updatedNodes, edges: updatedEdges } =
        highlightNodesAndEdges(nodes, edges, {
          activeTableName: activeTableName ?? undefined,
          hoverTableName: id,
        })

      setEdges(updatedEdges)
      setNodes(updatedNodes)
    },
    [edges, nodes, setNodes, setEdges, activeTableName],
  )

  const handleMouseLeaveNode: NodeMouseHandler<Node> = useCallback(() => {
    const { nodes: updatedNodes, edges: updatedEdges } = highlightNodesAndEdges(
      nodes,
      edges,
      {
        activeTableName: activeTableName ?? undefined,
        hoverTableName: undefined,
      },
    )

    setEdges(updatedEdges)
    setNodes(updatedNodes)
  }, [edges, nodes, setNodes, setEdges, activeTableName])

  const handleDragStopNode: OnNodeDrag<Node> = useCallback(
    (_event, _node, nodes) => {
      const operationId = `id_${Date.now()}`
      for (const node of nodes) {
        const tableId = node.id
        repositionTableLogEvent({
          tableId,
          operationId,
          platform: version.displayedOn,
          gitHash: version.gitHash,
          ver: version.version,
          appEnv: version.envName,
        })
      }
    },
    [version],
  )

  type ContextMenuState = { x: number; y: number; nodeId: string; isController: boolean }
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null)
  const contextMenuRef = useRef<HTMLDivElement>(null)

  const handleNodeContextMenu: NodeMouseHandler<Node> = useCallback(
    (event, node) => {
      event.preventDefault()
      const isController =
        node.type === 'woodsNode' &&
        (node as WoodsNodeType).data.type === 'controller'
      if (!isController) return
      setContextMenu({ x: event.clientX, y: event.clientY, nodeId: node.id, isController })
    },
    [],
  )

  const closeContextMenu = useCallback(() => setContextMenu(null), [])

  useEffect(() => {
    if (!contextMenu) return
    const handler = (e: MouseEvent) => {
      if (contextMenuRef.current && !contextMenuRef.current.contains(e.target as Element)) {
        closeContextMenu()
      }
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [contextMenu, closeContextMenu])

  const panOnDrag = [1, 2]

  return (
    <div className={styles.wrapper} data-loading={loading}>
      {loading && <Spinner className={styles.loading} />}
      {contextMenu && contextMenu.isController && (
        <div
          ref={contextMenuRef}
          className={styles.contextMenu}
          style={{ top: contextMenu.y, left: contextMenu.x }}
        >
          <button
            type="button"
            className={styles.contextMenuItem}
            onClick={() => {
              journeyCtx?.enterJourney({
                identifier: contextMenu.nodeId,
                verb: 'SYNTHETIC',
                path: '',
                action: '',
              })
              closeContextMenu()
            }}
          >
            Start journey from here
          </button>
        </div>
      )}
      <ReactFlow
        colorMode="dark"
        nodes={displayNodes}
        edges={displayEdges}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        edgesFocusable={false}
        edgesReconnectable={false}
        minZoom={MIN_ZOOM}
        maxZoom={MAX_ZOOM}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onNodeClick={(_, node) => handleNodeClick(node.id)}
        onPaneClick={handlePaneClick}
        onNodeMouseEnter={handleMouseEnterNode}
        onNodeMouseLeave={handleMouseLeaveNode}
        onNodeDragStop={handleDragStopNode}
        onNodeContextMenu={handleNodeContextMenu}
        panOnScroll
        panOnDrag={panOnDrag}
        deleteKeyCode={null} // Turn off because it does not want to be deleted
        attributionPosition="bottom-left"
        nodesConnectable={false}
      >
        <Background
          color="var(--color-gray-600)"
          variant={BackgroundVariant.Dots}
          size={1}
          gap={16}
        />
      </ReactFlow>
    </div>
  )
}

export const ERDContent: FC<Props> = (props) => {
  return (
    <ErdContentProvider>
      <ERDContentInner {...props} />
    </ErdContentProvider>
  )
}
