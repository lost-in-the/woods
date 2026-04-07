import type { WoodsNodeType } from '@liam-hq/schema'
import {
  BookText,
  Eye,
  EyeOff,
  GithubLogo,
  LiamLogoMark,
  Megaphone,
  MessagesSquare,
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from '@liam-hq/ui'
import type { Node } from '@xyflow/react'
import { useNodes } from '@xyflow/react'
import { type FC, useCallback, useMemo, useState } from 'react'
import { woodsNodeColors } from '@/features/erd/components/ERDContent/components/WoodsNode'
import type { NodeLayer } from '@/features/erd/components/LayerToggle'
import { isTableNode } from '@/features/erd/utils'
import { useCustomReactflow } from '@/features/reactflow/hooks'
import { useVersionOrThrow } from '@/providers'
import { useUserEditingOrThrow } from '@/stores'
import { updateNodesHiddenState } from '../../ERDContent/utils'
import { CopyLinkButton } from './CopyLinkButton'
import styles from './LeftPane.module.css'
import { MenuItemLink, type Props as MenuItemLinkProps } from './MenuItemLink'
import { TableNameMenuButton } from './TableNameMenuButton'

const WOODS_SECTIONS: {
  layer: NodeLayer
  label: string
  nodeType: WoodsNodeType
}[] = [
  { layer: 'controllers', label: 'Controllers', nodeType: 'controller' },
  { layer: 'jobs', label: 'Jobs', nodeType: 'job' },
  { layer: 'services', label: 'Services', nodeType: 'service' },
  { layer: 'mailers', label: 'Mailers', nodeType: 'mailer' },
]

const WoodsNodeGroup: FC<{
  label: string
  nodeType: WoodsNodeType
  nodes: Node[]
  onFocusNode: (nodeId: string | null) => void
}> = ({ label, nodeType, nodes, onFocusNode }) => {
  const [isOpen, setIsOpen] = useState(false)

  return (
    <SidebarGroup>
      <SidebarGroupLabel
        className={styles.groupLabel}
        onClick={() => setIsOpen((prev) => !prev)}
        style={{ cursor: 'pointer' }}
      >
        <span>{label} ({nodes.length})</span>
      </SidebarGroupLabel>
      {isOpen && (
        <SidebarGroupContent>
          <SidebarMenu className={styles.tablesMenu}>
            {nodes.map((node) => (
              <SidebarMenuItem key={node.id}>
                <SidebarMenuButton
                  className={styles.button}
                  onClick={() => onFocusNode(node.id)}
                >
                  <span
                    className={styles.colorDot}
                    style={{ backgroundColor: woodsNodeColors[nodeType].border }}
                  />
                  <span>{String(node.data['name'])}</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            ))}
          </SidebarMenu>
        </SidebarGroupContent>
      )}
    </SidebarGroup>
  )
}

type Props = {
  onFocusNode: (nodeId: string | null) => void
  nodeLayers: Record<NodeLayer, boolean>
}

export const LeftPane = ({ onFocusNode, nodeLayers }: Props) => {
  const { version } = useVersionOrThrow()
  const { selectedNodeIds, setHiddenNodeIds, resetSelectedNodeIds } =
    useUserEditingOrThrow()

  const { setNodes } = useCustomReactflow()

  const menuItemLinks = useMemo(
    (): MenuItemLinkProps[] => [
      {
        label: 'Release Notes',
        href: 'https://github.com/liam-hq/liam/releases',
        noreferrer: true,
        target: '_blank',
        icon: <Megaphone className={styles.icon} />,
      },
      {
        label: 'Documentation',
        href: 'https://liambx.com/docs',
        noreferrer: version.displayedOn === 'cli',
        target: '_blank',
        icon: <BookText className={styles.icon} />,
      },
      {
        label: 'Community Forum',
        href: 'https://github.com/liam-hq/liam/discussions',
        noreferrer: true,
        target: '_blank',
        icon: <MessagesSquare className={styles.icon} />,
      },
      {
        label: 'Go to Homepage',
        href: 'https://liambx.com/',
        noreferrer: version.displayedOn === 'cli',
        target: '_blank',
        icon: <LiamLogoMark className={styles.icon} />,
      },
      {
        label: 'Go to GitHub',
        href: 'https://github.com/liam-hq/liam',
        noreferrer: true,
        target: '_blank',
        icon: <GithubLogo className={styles.icon} />,
      },
    ],
    [version.displayedOn],
  )

  const nodes = useNodes()
  const tableNodes = useMemo(() => {
    return nodes.filter(isTableNode).sort((a, b) => {
      const nameA = a.data.table.name
      const nameB = b.data.table.name
      if (nameA < nameB) {
        return -1
      }
      if (nameA > nameB) {
        return 1
      }
      return 0
    })
  }, [nodes])

  const woodsNodesByType = useMemo(() => {
    const grouped: Record<string, Node[]> = {}
    for (const node of nodes) {
      if (node.type === 'woodsNode') {
        const nodeType = String(node.data['type'])
        if (!grouped[nodeType]) grouped[nodeType] = []
        grouped[nodeType].push(node)
      }
    }
    return grouped
  }, [nodes])

  const allCount = tableNodes.length
  const visibleCount = tableNodes.filter((node) => !node.hidden).length

  const showOrHideAllNodes = useCallback(() => {
    resetSelectedNodeIds()
    const shouldHide = visibleCount === allCount
    const updatedNodes = updateNodesHiddenState({
      nodes,
      hiddenNodeIds: shouldHide ? nodes.map((node) => node.id) : [],
      shouldHideGroupNodeId: true,
    })
    setNodes(updatedNodes)
    setHiddenNodeIds(shouldHide ? nodes.map((node) => node.id) : null)
  }, [
    nodes,
    visibleCount,
    allCount,
    setNodes,
    setHiddenNodeIds,
    resetSelectedNodeIds,
  ])

  const showSelectedTables = useCallback(() => {
    if (selectedNodeIds.size > 0) {
      const hiddenNodeIds = nodes
        .filter((node) => !selectedNodeIds.has(node.id))
        .map((node) => node.id)
      const updatedNodes = updateNodesHiddenState({
        nodes,
        hiddenNodeIds,
        shouldHideGroupNodeId: true,
      })
      setNodes(updatedNodes)
      setHiddenNodeIds(hiddenNodeIds)
    }
  }, [nodes, selectedNodeIds, setNodes, setHiddenNodeIds])

  return (
    <Sidebar>
      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel className={styles.groupLabel} asChild>
            <span>Tables</span>
            <span className={styles.tablesHeaderRow}>
              <button
                type="button"
                className={styles.showAllButton}
                aria-label={
                  visibleCount === allCount
                    ? 'Hide All Tables'
                    : 'Show All Tables'
                }
                tabIndex={0}
                onClick={showOrHideAllNodes}
              >
                {visibleCount === allCount ? (
                  <EyeOff className={styles.icon} />
                ) : (
                  <Eye className={styles.icon} />
                )}
                <span className={styles.showAllText}>
                  {visibleCount === allCount ? 'Hide All' : 'Show All'}
                </span>
                <span className={styles.visibleCount}>
                  ({visibleCount}/{allCount} visible)
                </span>
              </button>
            </span>
          </SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu className={styles.tablesMenu}>
              {tableNodes.map((node) => (
                <TableNameMenuButton
                  key={node.id}
                  node={node}
                  nodes={tableNodes}
                  showSelectedTables={showSelectedTables}
                  onFocus={onFocusNode}
                />
              ))}
            </SidebarMenu>

            <SidebarMenu className={styles.contentControls}>
              <CopyLinkButton />
            </SidebarMenu>

            <SidebarMenu className={styles.contentLinks}>
              {menuItemLinks.map((item) => (
                <MenuItemLink {...item} key={item.label} />
              ))}
              <SidebarMenuItem className={styles.versionWrapper}>
                <div className={styles.version}>
                  <span className={styles.versionText}>{`${
                    version.version
                  } + ${version.gitHash.slice(0, 7)} (${version.date})`}</span>
                </div>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>

        {WOODS_SECTIONS.map(({ layer, label, nodeType }) => {
          const sectionNodes = woodsNodesByType[nodeType] ?? []
          if (!nodeLayers[layer] || sectionNodes.length === 0) return null
          return (
            <WoodsNodeGroup
              key={layer}
              label={label}
              nodeType={nodeType}
              nodes={sectionNodes}
              onFocusNode={onFocusNode}
            />
          )
        })}
      </SidebarContent>
    </Sidebar>
  )
}
