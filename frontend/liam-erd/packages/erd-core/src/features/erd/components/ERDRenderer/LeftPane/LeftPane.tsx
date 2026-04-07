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
import { useNodes } from '@xyflow/react'
import { useCallback, useMemo } from 'react'
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

type Props = {
  focusedNode: string | null
  onFocusNode: (nodeId: string | null) => void
  nodeLayers: Record<NodeLayer, boolean>
}

export const LeftPane = ({ focusedNode, onFocusNode, nodeLayers }: Props) => {
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

  const woodsNodes = useMemo(
    () => nodes.filter((n) => n.type === 'woodsNode'),
    [nodes],
  )
  const controllerNodes = useMemo(
    () => woodsNodes.filter((n) => n.data.type === 'controller'),
    [woodsNodes],
  )
  const jobNodes = useMemo(
    () => woodsNodes.filter((n) => n.data.type === 'job'),
    [woodsNodes],
  )
  const serviceNodes = useMemo(
    () => woodsNodes.filter((n) => n.data.type === 'service'),
    [woodsNodes],
  )
  const mailerNodes = useMemo(
    () => woodsNodes.filter((n) => n.data.type === 'mailer'),
    [woodsNodes],
  )

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

        {nodeLayers.controllers && controllerNodes.length > 0 && (
          <SidebarGroup>
            <SidebarGroupLabel className={styles.groupLabel}>
              <span>Controllers</span>
            </SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu className={styles.tablesMenu}>
                {controllerNodes.map((node) => (
                  <SidebarMenuItem key={node.id}>
                    <SidebarMenuButton
                      className={styles.button}
                      onClick={() => onFocusNode(node.id)}
                    >
                      <span
                        className={styles.colorDot}
                        style={{ backgroundColor: '#60a5fa' }}
                      />
                      <span>{String(node.data.name)}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        )}

        {nodeLayers.jobs && jobNodes.length > 0 && (
          <SidebarGroup>
            <SidebarGroupLabel className={styles.groupLabel}>
              <span>Jobs</span>
            </SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu className={styles.tablesMenu}>
                {jobNodes.map((node) => (
                  <SidebarMenuItem key={node.id}>
                    <SidebarMenuButton
                      className={styles.button}
                      onClick={() => onFocusNode(node.id)}
                    >
                      <span
                        className={styles.colorDot}
                        style={{ backgroundColor: '#fbbf24' }}
                      />
                      <span>{String(node.data.name)}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        )}

        {nodeLayers.services && serviceNodes.length > 0 && (
          <SidebarGroup>
            <SidebarGroupLabel className={styles.groupLabel}>
              <span>Services</span>
            </SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu className={styles.tablesMenu}>
                {serviceNodes.map((node) => (
                  <SidebarMenuItem key={node.id}>
                    <SidebarMenuButton
                      className={styles.button}
                      onClick={() => onFocusNode(node.id)}
                    >
                      <span
                        className={styles.colorDot}
                        style={{ backgroundColor: '#c084fc' }}
                      />
                      <span>{String(node.data.name)}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        )}

        {nodeLayers.mailers && mailerNodes.length > 0 && (
          <SidebarGroup>
            <SidebarGroupLabel className={styles.groupLabel}>
              <span>Mailers</span>
            </SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu className={styles.tablesMenu}>
                {mailerNodes.map((node) => (
                  <SidebarMenuItem key={node.id}>
                    <SidebarMenuButton
                      className={styles.button}
                      onClick={() => onFocusNode(node.id)}
                    >
                      <span
                        className={styles.colorDot}
                        style={{ backgroundColor: '#f472b6' }}
                      />
                      <span>{String(node.data.name)}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        )}
      </SidebarContent>
    </Sidebar>
  )
}
